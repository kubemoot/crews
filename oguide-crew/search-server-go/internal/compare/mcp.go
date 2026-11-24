// Package compare runs the Python and the Go O'guide search servers on the same recorded queries
// and reports how their answers differ. Each server is a child process that speaks MCP on stdio and
// calls one gateway address; nothing else is in its environment, so neither can see a credential.
package compare

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os/exec"
	"strings"
	"time"
)

const callTimeout = 90 * time.Second

// Query is one recorded tool call.
type Query struct {
	Name      string         `json:"name"`
	Tool      string         `json:"tool"`
	Arguments map[string]any `json:"arguments"`
	Meta      map[string]any `json:"meta,omitempty"`
}

// Answer is what a server gave for one query: the tool's text result and whether it was an error,
// or a protocol error.
type Answer struct {
	Text     string
	IsError  bool
	Protocol string
}

// Server is a search server started as a child process.
type Server struct {
	cmd    *exec.Cmd
	in     io.WriteCloser
	out    *bufio.Reader
	nextID int
}

// Start runs the command (program and arguments) with exactly this environment.
func Start(command []string, env []string) (*Server, error) {
	if len(command) == 0 {
		return nil, errors.New("no command")
	}
	cmd := exec.Command(command[0], command[1:]...) // #nosec G204 -- the operator names the servers to compare
	cmd.Env = env
	in, err := cmd.StdinPipe()
	if err != nil {
		return nil, err
	}
	out, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	return &Server{cmd: cmd, in: in, out: bufio.NewReaderSize(out, 1<<20)}, nil
}

// Stop ends the child process.
func (s *Server) Stop() {
	_ = s.in.Close()
	_ = s.cmd.Wait()
}

// request sends one JSON-RPC request and returns the reply's result or error.
func (s *Server) request(method string, params any) (json.RawMessage, error) {
	s.nextID++
	line, err := json.Marshal(map[string]any{"jsonrpc": "2.0", "id": s.nextID, "method": method, "params": params})
	if err != nil {
		return nil, err
	}
	if _, err := s.in.Write(append(line, '\n')); err != nil {
		return nil, err
	}
	type readResult struct {
		line []byte
		err  error
	}
	done := make(chan readResult, 1)
	go func() {
		text, err := s.out.ReadBytes('\n')
		done <- readResult{text, err}
	}()
	select {
	case got := <-done:
		if got.err != nil {
			return nil, got.err
		}
		return replyOf(got.line)
	case <-time.After(callTimeout):
		_ = s.cmd.Process.Kill()
		return nil, fmt.Errorf("%s: no answer in %s", method, callTimeout)
	}
}

func replyOf(line []byte) (json.RawMessage, error) {
	var reply struct {
		Result json.RawMessage `json:"result"`
		Error  *struct {
			Code    int    `json:"code"`
			Message string `json:"message"`
		} `json:"error"`
	}
	dec := json.NewDecoder(bytes.NewReader(line))
	if err := dec.Decode(&reply); err != nil {
		return nil, err
	}
	if reply.Error != nil {
		return nil, fmt.Errorf("protocol error %d: %s", reply.Error.Code, reply.Error.Message)
	}
	return reply.Result, nil
}

// Initialize opens the MCP session.
func (s *Server) Initialize() error {
	_, err := s.request("initialize", map[string]any{"protocolVersion": "2025-03-26"})
	return err
}

// Tools is the tools/list result as plain JSON values.
func (s *Server) Tools() (any, error) {
	raw, err := s.request("tools/list", map[string]any{})
	if err != nil {
		return nil, err
	}
	var listing any
	return listing, json.Unmarshal(raw, &listing)
}

// Call runs one recorded query.
func (s *Server) Call(query Query) Answer {
	params := map[string]any{"name": query.Tool, "arguments": query.Arguments}
	if query.Meta != nil {
		params["_meta"] = query.Meta
	}
	raw, err := s.request("tools/call", params)
	if err != nil {
		return Answer{Protocol: err.Error()}
	}
	var result struct {
		Content []struct {
			Text string `json:"text"`
		} `json:"content"`
		IsError bool `json:"isError"`
	}
	if err := json.Unmarshal(raw, &result); err != nil || len(result.Content) == 0 {
		return Answer{Protocol: "a result without content: " + strings.TrimSpace(string(raw))}
	}
	return Answer{Text: result.Content[0].Text, IsError: result.IsError}
}
