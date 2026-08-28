package core

import (
	"math"
	"reflect"
	"testing"
)

// samePosition replaced reflect.DeepEqual on the per-frame suppression path, so
// the only thing it is allowed to be is DeepEqual without the reflection. It is
// checked AGAINST DeepEqual rather than against hand-written expectations: a
// hand-written table can encode the same misunderstanding twice and agree with
// itself, and the cases that matter here are precisely the ones somebody would
// get wrong from memory.
//
// Suppression decides whether a state goes on the wire at all (ADR 0039), so a
// disagreement here is not a slow path -- it is a ghost that stops updating, or
// traffic the user was told would not be sent.
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

// Spelled out separately because it is the one case a "simplification" would
// break silently: len(nil) == len([]float64{}) == 0, so a bare length-then-loop
// comparison calls these equal where DeepEqual does not.
func TestSamePositionDistinguishesNilFromEmpty(t *testing.T) {
	if samePosition(nil, []float64{}) {
		t.Fatal("nil and empty must differ, as they do for reflect.DeepEqual")
	}
	if !samePosition(nil, nil) || !samePosition([]float64{}, []float64{}) {
		t.Fatal("a value must equal itself")
	}
}

// The two NaN cases, which are the ones the table above would not have
// separated on its own and which reflect.DeepEqual treats differently from each
// other. Distinct slices compare element-wise, so NaN != NaN and the state is
// sent; the SAME slice hits DeepEqual's documented "same backing array, same
// length" shortcut and is equal without any element being examined.
//
// The aliased case is live, not academic: forwardLocalState's `kept := *state`
// shares the adapter's Position array, so prev and cur can be the same memory
// on the very next frame. Getting this wrong would have changed which frames
// get suppressed for any adapter that reuses its position slice.
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
