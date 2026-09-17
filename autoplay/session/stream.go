package session

import (
	"bufio"
	"encoding/json"
	"io"
)

// Counter reads a headless Claude Code run's stream-json output line by line and counts its model calls: each
// response the model makes carries one message id, and a response with several content blocks arrives as several
// lines with the same id (code.claude.com/docs/en/headless.md, read 2026-09-17; checked on the dry run before relying
// on it). The result line's cost field is never read.
type Counter struct {
	ids       map[string]bool
	SessionID string
	ToolUses  map[string]int
	// Result is set once the run's result line is read.
	Result *struct {
		Subtype  string `json:"subtype"`
		IsError  bool   `json:"is_error"`
		NumTurns int    `json:"num_turns"`
		Text     string `json:"result"`
	}
	LastText string
}

// NewCounter makes an empty counter.
func NewCounter() *Counter {
	return &Counter{ids: map[string]bool{}, ToolUses: map[string]int{}}
}

// Calls is the model calls counted so far.
func (c *Counter) Calls() int { return len(c.ids) }

// Line reads one line of the stream and reports whether it added a model call.
func (c *Counter) Line(line []byte) bool {
	var ev struct {
		Type      string `json:"type"`
		Subtype   string `json:"subtype"`
		SessionID string `json:"session_id"`
		Message   struct {
			ID      string `json:"id"`
			Content []struct {
				Type string `json:"type"`
				Name string `json:"name"`
				Text string `json:"text"`
			} `json:"content"`
		} `json:"message"`
		IsError  bool   `json:"is_error"`
		NumTurns int    `json:"num_turns"`
		Result   string `json:"result"`
		// A subagent's lines carry the tool use they belong to; they are model calls all the same.
		ParentToolUseID *string `json:"parent_tool_use_id"`
	}
	if json.Unmarshal(line, &ev) != nil {
		return false
	}
	if ev.SessionID != "" && c.SessionID == "" {
		c.SessionID = ev.SessionID
	}
	switch ev.Type {
	case "assistant":
		added := false
		if ev.Message.ID != "" && !c.ids[ev.Message.ID] {
			c.ids[ev.Message.ID] = true
			added = true
		}
		for _, b := range ev.Message.Content {
			switch b.Type {
			case "tool_use":
				c.ToolUses[b.Name]++
			case "text":
				if b.Text != "" {
					c.LastText = b.Text
				}
			}
		}
		return added
	case "result":
		c.Result = &struct {
			Subtype  string `json:"subtype"`
			IsError  bool   `json:"is_error"`
			NumTurns int    `json:"num_turns"`
			Text     string `json:"result"`
		}{ev.Subtype, ev.IsError, ev.NumTurns, ev.Result}
	}
	return false
}

// Read counts a whole stream, calling each after every line that added a model call, and copying every line to copyTo
// when it is not nil. It returns when the stream ends.
func (c *Counter) Read(r io.Reader, copyTo io.Writer, each func(calls int)) error {
	br := bufio.NewReaderSize(r, 1<<20)
	for {
		line, err := br.ReadBytes('\n')
		if len(line) > 0 {
			if copyTo != nil {
				copyTo.Write(line)
			}
			if c.Line(line) && each != nil {
				each(c.Calls())
			}
		}
		if err == io.EOF {
			return nil
		}
		if err != nil {
			return err
		}
	}
}
