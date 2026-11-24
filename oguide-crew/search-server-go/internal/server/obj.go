package server

import (
	"bytes"
	"encoding/json"
)

// obj is a JSON object that keeps its keys in the order they were first set, so the
// results read the same as the Python server's dicts: today, dateSource, then the lists.
type obj struct {
	keys []string
	vals map[string]any
}

func newObj() *obj {
	return &obj{vals: map[string]any{}}
}

// set stores a value; an existing key keeps its position.
func (o *obj) set(key string, value any) *obj {
	if _, found := o.vals[key]; !found {
		o.keys = append(o.keys, key)
	}
	o.vals[key] = value
	return o
}

func (o *obj) get(key string) any {
	return o.vals[key]
}

func (o *obj) has(key string) bool {
	_, found := o.vals[key]
	return found
}

// MarshalJSON writes the keys in order.
func (o *obj) MarshalJSON() ([]byte, error) {
	var out bytes.Buffer
	out.WriteByte('{')
	for i, key := range o.keys {
		if i > 0 {
			out.WriteByte(',')
		}
		name, err := encodeJSON(key)
		if err != nil {
			return nil, err
		}
		value, err := encodeJSON(o.vals[key])
		if err != nil {
			return nil, err
		}
		out.WriteString(name)
		out.WriteByte(':')
		out.WriteString(value)
	}
	out.WriteByte('}')
	return out.Bytes(), nil
}

// encodeJSON is json.Marshal without the HTML escaping of <, > and &, which the model would
// otherwise read as <.
func encodeJSON(value any) (string, error) {
	var out bytes.Buffer
	enc := json.NewEncoder(&out)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(value); err != nil {
		return "", err
	}
	return string(bytes.TrimRight(out.Bytes(), "\n")), nil
}

// truthy follows Python's rule for "x or default": empty values are false.
func truthy(value any) bool {
	switch v := value.(type) {
	case nil:
		return false
	case bool:
		return v
	case string:
		return v != ""
	case json.Number, float64, int:
		return numberTruthy(v)
	default:
		return containerTruthy(value)
	}
}

func numberTruthy(value any) bool {
	switch v := value.(type) {
	case json.Number:
		f, err := v.Float64()
		return err != nil || f != 0
	case float64:
		return v != 0
	default:
		return value != 0
	}
}

// containerTruthy is false for an empty list or object; any other value is true.
func containerTruthy(value any) bool {
	switch v := value.(type) {
	case []any:
		return len(v) > 0
	case []string:
		return len(v) > 0
	case map[string]any:
		return len(v) > 0
	default:
		return true
	}
}

// isList is true for a JSON array, however it was built.
func isList(value any) bool {
	switch value.(type) {
	case []any, []Entry, []string:
		return true
	default:
		return false
	}
}

func listLen(value any) int {
	switch v := value.(type) {
	case []any:
		return len(v)
	case []Entry:
		return len(v)
	case []string:
		return len(v)
	default:
		return 0
	}
}
