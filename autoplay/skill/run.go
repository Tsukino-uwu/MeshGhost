package skill

import (
	"context"
	"encoding/json"
	"fmt"

	"github.com/Tsukino-uwu/MeshGhost/autoplay/scenario"
)

// Outcomes a run ends on.
const (
	OutcomeDone      = "done"       // a rule said done
	OutcomeStopped   = "stopped"    // a rule said stop
	OutcomeNoRule    = "no_rule"    // no rule matched the last answer: the caller decides
	OutcomeMaxCalls  = "max_calls"  // the skill made its max_calls and a rule still asked for another
	OutcomeToolError = "tool_error" // a call was refused or failed; the last answer holds the error text
	OutcomeLoop      = "loop"       // the core marked an answer as a loop (server's LOOPS): the same answer at the same place again
)

// Loader finds a skill by name.
type Loader interface {
	Load(name string) (*Skill, error)
}

// Step is one call a run made, as its trail lists it.
type Step struct {
	Call    string `json:"call"`
	Outcome string `json:"outcome,omitempty"`
	Error   bool   `json:"error,omitempty"`
	// Rule is the 1-based rule that matched the answer, 0 when none did.
	Rule int `json:"rule,omitempty"`
}

// Result is a run's answer.
type Result struct {
	Skill   string `json:"skill"`
	Outcome string `json:"outcome"`
	Reason  string `json:"reason,omitempty"`
	Draft   bool   `json:"draft,omitempty"`
	// Calls counts every tool call made, those of nested skills included.
	Calls int    `json:"calls"`
	Trail []Step `json:"trail"`
	// Last is the last call and its whole answer (JSON, or the error's text), for the caller to decide on.
	LastCall string `json:"last_call,omitempty"`
	Last     any    `json:"last,omitempty"`
}

// OutcomeWord is the word the run ended on, as the run log keeps it.
func (r Result) OutcomeWord() string { return r.Outcome }

// Runner runs skills through a Caller.
type Runner struct {
	Caller scenario.Caller
	Skills Loader
	// Tools names the tools the server has; a skill naming another is refused before its first call.
	Tools map[string]bool
}

// Run loads the skill name, checks it and every skill it calls, and runs it with args. The error is for a skill that
// cannot be run at all (missing, invalid, wrong arguments) or the server failing; a run that ends badly is a Result.
func (rn Runner) Run(ctx context.Context, name string, args map[string]any) (Result, error) {
	loaded := map[string]*Skill{}
	if err := rn.resolve(name, loaded, 0); err != nil {
		return Result{Skill: name}, err
	}
	if args == nil {
		args = map[string]any{}
	}
	if err := loaded[name].checkArgs(args); err != nil {
		return Result{Skill: name}, err
	}
	return rn.run(ctx, loaded, name, args, 0)
}

// resolve loads a skill and every skill it names, and checks each tool it names exists.
func (rn Runner) resolve(name string, loaded map[string]*Skill, depth int) error {
	if _, done := loaded[name]; done {
		return nil
	}
	if depth >= MaxDepth {
		return fmt.Errorf("skill %s: skills call each other deeper than %d", name, MaxDepth)
	}
	s, err := rn.Skills.Load(name)
	if err != nil {
		return err
	}
	loaded[name] = s
	actions := []Action{s.Call}
	for _, r := range s.Rules {
		if r.Then.Action != nil {
			actions = append(actions, *r.Then.Action)
		}
	}
	for _, a := range actions {
		if a.Tool != "" && rn.Tools != nil && !rn.Tools[a.Tool] {
			return fmt.Errorf("skill %s calls %q, which the server does not have", name, a.Tool)
		}
		if a.Skill != "" {
			if err := rn.resolve(a.Skill, loaded, depth+1); err != nil {
				return err
			}
		}
	}
	return nil
}

func (rn Runner) run(ctx context.Context, loaded map[string]*Skill, name string, args map[string]any, depth int) (Result, error) {
	s := loaded[name]
	res := Result{Skill: name, Draft: s.Draft, Trail: []Step{}}
	next := s.Call
	own := 0
	fired := make([]int, len(s.Rules))
	for {
		if err := ctx.Err(); err != nil {
			return res, err
		}
		if own == s.MaxCalls {
			res.Outcome, res.Reason = OutcomeMaxCalls, fmt.Sprintf("%d calls made and a rule asked for another (%s)", own, next.Name())
			return res, nil
		}
		own++
		answer, isErr, calls, err := rn.call(ctx, loaded, next, args, depth)
		res.Calls += calls
		if err != nil {
			return res, err
		}
		step := Step{Call: next.Name(), Error: isErr}
		if m, ok := answer.(map[string]any); ok {
			if w, ok := m["outcome"].(string); ok {
				step.Outcome = w
			}
		}
		res.LastCall, res.Last = next.Name(), answer
		if isErr {
			res.Trail = append(res.Trail, step)
			res.Outcome, res.Reason = OutcomeToolError, fmt.Sprintf("%s answered an error", next.Name())
			return res, nil
		}
		if m, ok := answer.(map[string]any); ok {
			if loop, ok := m["loop"].(map[string]any); ok {
				res.Trail = append(res.Trail, step)
				res.Outcome, res.Reason = OutcomeLoop, fmt.Sprint(loop["note"])
				return res, nil
			}
		}
		rule, spent := match(s, next.Name(), answer, fired)
		if rule < 0 {
			res.Trail = append(res.Trail, step)
			res.Outcome, res.Reason = OutcomeNoRule, fmt.Sprintf("no rule after %s matched its answer", next.Name())
			if spent > 0 {
				res.Reason += fmt.Sprintf(" (rule %d matched and had decided its max %d times)", spent, s.Rules[spent-1].Max)
			}
			return res, nil
		}
		fired[rule]++
		step.Rule = rule + 1
		res.Trail = append(res.Trail, step)
		r := s.Rules[rule]
		switch {
		case r.Then.Action != nil:
			next = *r.Then.Action
		case r.Then.Word == ThenRepeat:
			next = s.Call
		case r.Then.Word == ThenDone:
			res.Outcome, res.Reason = OutcomeDone, r.Note
			return res, nil
		default:
			res.Outcome, res.Reason = OutcomeStopped, r.Note
			return res, nil
		}
	}
}

// call makes one action: a tool call, or a nested skill run. It returns the answer decoded (a nested run's Result as
// JSON would decode, so rules read it the same way), whether it was an error, and the tool calls it took.
func (rn Runner) call(ctx context.Context, loaded map[string]*Skill, a Action, args map[string]any, depth int) (any, bool, int, error) {
	callArgs, _ := substitute(a.Args, args).(map[string]any)
	if a.Skill != "" {
		sub := loaded[a.Skill]
		if err := sub.checkArgs(callArgs); err != nil {
			return err.Error(), true, 0, nil
		}
		res, err := rn.run(ctx, loaded, a.Skill, orEmpty(callArgs), depth+1)
		if err != nil {
			return nil, false, res.Calls, err
		}
		var decoded any
		b, _ := json.Marshal(res)
		json.Unmarshal(b, &decoded)
		return decoded, false, res.Calls, nil
	}
	text, isErr, err := rn.Caller.Call(ctx, a.Tool, orEmpty(callArgs))
	if err != nil {
		return nil, false, 1, fmt.Errorf("%s: %w", a.Tool, err)
	}
	var decoded any
	if isErr || json.Unmarshal([]byte(text), &decoded) != nil {
		return text, isErr, 1, nil
	}
	return decoded, false, 1, nil
}

func orEmpty(m map[string]any) map[string]any {
	if m == nil {
		return map[string]any{}
	}
	return m
}

// match returns the index of the first rule after call whose expectations all hold on answer and that has not decided its
// max times, or -1; spent is the 1-based first rule that held but had, 0 when none.
func match(s *Skill, call string, answer any, fired []int) (index, spent int) {
	for i := range s.Rules {
		r := &s.Rules[i]
		if r.After != call {
			continue
		}
		holds := true
		for j := range r.When {
			if r.When[j].Check(answer) != "" {
				holds = false
				break
			}
		}
		if holds && r.Max > 0 && fired[i] >= r.Max {
			if spent == 0 {
				spent = i + 1
			}
			continue
		}
		if holds {
			return i, spent
		}
	}
	return -1, spent
}
