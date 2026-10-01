package core

import (
	"math"
	"reflect"
	"testing"
)

// TestSamePositionMatchesDeepEqual: samePosition may only be reflect.DeepEqual without the reflection, so it is checked
// against DeepEqual, not a hand-written table that could encode the same misunderstanding twice. Suppression decides
// whether a state goes on the wire at all: a disagreement is a ghost that stops updating, or traffic never meant to go.
func TestSamePositionMatchesDeepEqual(t *testing.T) {
	nan := math.NaN()
	values := [][]float64{
		nil,
		{},
		{0},
		{-0.0},
		{1, 2},
		{1, 2, 3},
		{1, 2, 4},
		{2, 1},
		{math.Inf(1)},
		{math.Inf(-1)},
		{nan},
		{1, nan},
		{math.MaxFloat64},
		{math.SmallestNonzeroFloat64},
	}

	for i, a := range values {
		for j, b := range values {
			want := reflect.DeepEqual(a, b)
			if got := samePosition(a, b); got != want {
				t.Fatalf("samePosition(values[%d]=%v, values[%d]=%v) = %v, DeepEqual says %v",
					i, a, j, b, got, want)
			}
		}
	}
}

// TestSamePositionDistinguishesNilFromEmpty: a bare length-then-loop "simplification" calls nil and empty equal, where
// DeepEqual does not.
func TestSamePositionDistinguishesNilFromEmpty(t *testing.T) {
	if samePosition(nil, []float64{}) {
		t.Fatal("nil and empty must differ, as they do for reflect.DeepEqual")
	}
	if !samePosition(nil, nil) || !samePosition([]float64{}, []float64{}) {
		t.Fatal("a value must equal itself")
	}
}

// TestSamePositionNaNFollowsDeepEqualBothWays: distinct NaN slices compare element-wise and differ, while the same
// slice hits DeepEqual's "same backing array, same length" shortcut and is equal. The aliased case is live:
// forwardLocalState's `kept := *state` shares the adapter's Position array, so prev and cur can be the same memory.
func TestSamePositionNaNFollowsDeepEqualBothWays(t *testing.T) {
	shared := []float64{math.NaN()}
	if !samePosition(shared, shared) {
		t.Fatal("an aliased slice must be equal to itself, as reflect.DeepEqual has it")
	}
	if !reflect.DeepEqual(shared, shared) {
		t.Fatal("sanity: DeepEqual is expected to short-circuit on aliasing")
	}

	distinct := []float64{math.NaN()}
	if samePosition(shared, distinct) {
		t.Fatal("two distinct NaN slices must not compare equal")
	}
	if reflect.DeepEqual(shared, distinct) {
		t.Fatal("sanity: DeepEqual compares NaN element-wise for distinct slices")
	}
}
