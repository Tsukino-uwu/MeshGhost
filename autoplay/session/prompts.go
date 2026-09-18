package session

import (
	_ "embed"
	"strings"
	"text/template"
)

// The prompts a session is given: play.md to play toward the goal, distill.md to write down what was learned. Their
// fields: Game, GameTitle, Goal, GoalDescription, Budget, Date.
var (
	//go:embed play.md
	PlayPrompt string
	//go:embed distill.md
	DistillPrompt string
)

// Fill fills a prompt's fields; a field missing from vars is an error, never an empty gap.
func Fill(text string, vars map[string]any) (string, error) {
	t, err := template.New("prompt").Option("missingkey=error").Parse(text)
	if err != nil {
		return "", err
	}
	var b strings.Builder
	if err := t.Execute(&b, vars); err != nil {
		return "", err
	}
	return b.String(), nil
}
