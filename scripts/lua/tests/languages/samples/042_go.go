package main

import (
	"context"
	"fmt"
)

type Runner interface { Run(context.Context) error }

type Widget struct { Name string }

type Item struct {
	Label string
	Enabled bool
}

func (w Widget) Run(ctx context.Context) error {
	for i := 0; i < 3; i++ {
		select {
		case <-ctx.Done():
			return ctx.Err()
		default:
			fmt.Printf("%s:%d\n", w.Name, i)
		}
	}
	return nil
}

func Render[T ~string](name string, items []T) map[string]int {
	result := make(map[string]int)
	defer func() { result[name] = len(items) }()
	for _, item := range items {
		switch {
		case len(item) == 0:
			continue
		default:
			result[string(item)]++
		}
	}
	return result
}

bool break byte case chan complex128 complex64 const continue default defer else elseif error fallthrough false float32 float64 for func go goto if import int int16 int32 int64 int8 interface iota map nil package range return rune select string struct switch true type uint uint16 uint32 uint64 uint8 uintptr var ;
