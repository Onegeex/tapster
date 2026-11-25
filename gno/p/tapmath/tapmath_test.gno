package tapmath

import "testing"

func TestMedian(t *testing.T) {
	cases := []struct {
		in   []int64
		want int64
	}{
		{[]int64{5}, 5},
		{[]int64{3, 1, 2}, 2},
		{[]int64{4, 1, 3, 2}, 2},
		{[]int64{10, 20}, 15},
		{[]int64{11, 20}, 15},
		{[]int64{100, 100, 100, 9999}, 100},
		{[]int64{9223372036854775807, 9223372036854775807}, 9223372036854775807},
	}
	for _, c := range cases {
		if got := Median(c.in); got != c.want {
			t.Errorf("Median(%v) = %d, want %d", c.in, got, c.want)
		}
	}
}

func TestMedianDoesNotMutate(t *testing.T) {
	in := []int64{3, 1, 2}
	Median(in)
	if in[0] != 3 || in[1] != 1 || in[2] != 2 {
		t.Errorf("input mutated: %v", in)
	}
}

func TestMedianEmptyPanics(t *testing.T) {
	defer func() {
		if recover() == nil {
			t.Errorf("expected panic")
		}
	}()
	Median(nil)
}

func TestWeightedMedian(t *testing.T) {
	cases := []struct {
		v, w []int64
		want int64
	}{
		{[]int64{10}, []int64{5}, 10},
		{[]int64{10, 20, 30}, []int64{1, 1, 1}, 20},
		// A heavy honest reporter outweighs two light liars.
		{[]int64{100, 500, 500}, []int64{10, 2, 2}, 100},
		// Two light liars cannot move it, even when they agree.
		{[]int64{500, 100, 500}, []int64{3, 10, 3}, 100},
		// When liars hold the majority of stake, they win: the cost is stake.
		{[]int64{100, 500, 500}, []int64{2, 3, 3}, 500},
		{[]int64{30, 10, 20, 40}, []int64{1, 1, 1, 1}, 20},
	}
	for _, c := range cases {
		if got := WeightedMedian(c.v, c.w); got != c.want {
			t.Errorf("WeightedMedian(%v,%v)=%d want %d", c.v, c.w, got, c.want)
		}
	}
}

func TestWeightedMedianBadInput(t *testing.T) {
	for _, f := range []func(){
		func() { WeightedMedian(nil, nil) },
		func() { WeightedMedian([]int64{1}, []int64{0}) },
		func() { WeightedMedian([]int64{1, 2}, []int64{1}) },
	} {
		func() {
			defer func() {
				if recover() == nil {
					t.Errorf("expected panic")
				}
			}()
			f()
		}()
	}
}

func TestDeviationBps(t *testing.T) {
	if got := DeviationBps(101, 100); got != 100 {
		t.Errorf("got %d want 100", got)
	}
	if got := DeviationBps(95, 100); got != 500 {
		t.Errorf("got %d want 500", got)
	}
	if got := DeviationBps(100, 100); got != 0 {
		t.Errorf("got %d want 0", got)
	}
	if !Within(1005, 1000, 50) || Within(1006, 1000, 50) {
		t.Errorf("Within boundary wrong")
	}
}

func TestApplyBps(t *testing.T) {
	if got := ApplyBps(1000000, 500); got != 50000 {
		t.Errorf("got %d", got)
	}
	if got := ApplyBps(9223372036854775807, 10000); got != 9223372036854775807 {
		t.Errorf("no overflow at 100%%, got %d", got)
	}
	if got := ApplyBps(3, 5000); got != 1 {
		t.Errorf("got %d want 1", got)
	}
}

func TestUsdCentsToUgnot(t *testing.T) {
	// $0.06 per GNOT, $6.00 -> 100 GNOT.
	if got := UsdCentsToUgnot(600, 60000, 6); got != 100000000 {
		t.Errorf("got %d", got)
	}
	// Rounds up: $0.01 at $0.07 -> 0.142857.. GNOT -> 142858 ugnot.
	if got := UsdCentsToUgnot(1, 70000, 6); got != 142858 {
		t.Errorf("got %d", got)
	}
	// 8 decimals works.
	if got := UsdCentsToUgnot(100, 100000000, 8); got != 1000000 {
		t.Errorf("got %d", got)
	}
	if got := UsdCentsToUgnot(0, 60000, 6); got != 0 {
		t.Errorf("got %d", got)
	}
}

func TestRoundTrip(t *testing.T) {
	price := int64(63361)
	for _, cents := range []int64{1, 99, 1500, 123456} {
		u := UsdCentsToUgnot(cents, price, 6)
		back := UgnotToUsdCents(u, price, 6)
		if back < cents {
			t.Errorf("rounding lost value: %d cents -> %d ugnot -> %d cents", cents, u, back)
		}
	}
}

func TestFormat(t *testing.T) {
	cases := []struct {
		v    int64
		d    int
		want string
	}{
		{60123, 6, "0.060123"},
		{91234560000, 6, "91234.560000"},
		{5, 2, "0.05"},
		{-150, 2, "-1.50"},
		{42, 0, "42"},
	}
	for _, c := range cases {
		if got := FormatFixed(c.v, c.d); got != c.want {
			t.Errorf("FormatFixed(%d,%d)=%s want %s", c.v, c.d, got, c.want)
		}
	}
	if got := FormatRounded(91234567890, 6, 2); got != "91234.56" {
		t.Errorf("FormatRounded got %s", got)
	}
}
