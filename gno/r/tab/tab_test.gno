package tab

import (
	"chain"
	"chain/banker"
	"strings"
	"testing"

	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
	"gno.land/p/nt/urequire/v0"
	"gno.land/r/tapsterns/tapster/v0"
)

var (
	alice     = testutils.TestAddress("alice") // reporter
	bob       = testutils.TestAddress("bob")   // reporter
	barkeep   = testutils.TestAddress("barkeep")
	guest     = testutils.TestAddress("guest")
	oracle    = chain.PackageAddress("gno.land/r/tapsterns/tapster/v0")
	tabRealm  = chain.PackageAddress("gno.land/r/tapsterns/tab/v0")
)

func coins(n int64) chain.Coins { return chain.NewCoins(chain.NewCoin("ugnot", n)) }

func withSend(to address, n int64) {
	testing.SetOriginSend(coins(n))
	testing.IssueCoins(to, coins(n))
}

func TestTabFlow(cur realm, t *testing.T) {
	// Before any price exists, quoting is refused.
	testing.SetRealm(testing.NewUserRealm(barkeep))
	id := Open(cross(cur), "Friday night")
	Add(cross(cur), id, "Mead", 650)
	Add(cross(cur), id, "Bread", 350)
	uassert.Equal(t, int64(1000), Total(id))
	_, _, ok := Quote(id)
	uassert.False(t, ok)
	urequire.True(t, strings.Contains(Render("tab/1"), "paused"))

	// Two reporters publish GNOT-USD = $0.05 (50000 with 6 decimals).
	testing.SetRealm(testing.NewUserRealm(alice))
	withSend(oracle, 1000000)
	tapster.Stake(cross(cur), "alice")
	testing.SetRealm(testing.NewUserRealm(bob))
	withSend(oracle, 1000000)
	tapster.Stake(cross(cur), "bob")
	testing.SkipHeights(61)
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(nil)
	tapster.Submit(cross(cur), "GNOT-USD", 50000)
	testing.SetRealm(testing.NewUserRealm(bob))
	tapster.Submit(cross(cur), "GNOT-USD", 50000)
	testing.SkipHeights(61)
	tapster.Finalize(cross(cur), "GNOT-USD")

	// $10.00 at $0.05 = 200 GNOT.
	due, price, ok := Quote(id)
	uassert.True(t, ok)
	uassert.Equal(t, int64(50000), price)
	uassert.Equal(t, int64(200000000), due)

	// Only the bartender adds items.
	testing.SetRealm(testing.NewUserRealm(guest))
	uassert.AbortsContains(t, cur, "only the bartender", func(cur realm) { Add(cur, id, "Free beer", 1) })

	// Underpaying is refused.
	withSend(tabRealm, 199999999)
	uassert.AbortsContains(t, cur, "not enough GNOT", func(cur realm) { Pay(cur, id) })

	// Overpay; the change is refunded and the bartender gets exactly due.
	testing.SetRealm(testing.NewUserRealm(guest))
	withSend(tabRealm, 204000000)
	Pay(cross(cur), id)
	ro := banker.NewReadonlyBanker()
	uassert.Equal(t, int64(200000000), ro.GetCoins(barkeep).AmountOf("ugnot"))
	uassert.Equal(t, int64(4000000), ro.GetCoins(guest).AmountOf("ugnot"))
	tb := mustTab(id)
	uassert.True(t, tb.Paid)
	uassert.Equal(t, int64(200000000), tb.PaidUgnot)
	urequire.True(t, strings.Contains(Render("tab/1"), "Paid 200.0000 GNOT"))

	testing.SetRealm(testing.NewUserRealm(guest))
	withSend(tabRealm, 204000000)
	uassert.AbortsContains(t, cur, "already paid", func(cur realm) { Pay(cur, id) })
}

func TestPayRequiresFreshPrice(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(barkeep))
	id := Open(cross(cur), "Late night")
	Add(cross(cur), id, "Water", 100)
	testing.SkipHeights(2000) // the last price is now far too old
	testing.SetRealm(testing.NewUserRealm(guest))
	withSend(tabRealm, 999999999)
	uassert.AbortsContains(t, cur, "no fresh price", func(cur realm) { Pay(cur, id) })
}

func TestPayRejectsCodeRealm(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(barkeep))
	id := Open(cross(cur), "Trap")
	Add(cross(cur), id, "Ale", 100)
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/attacker/wrapper"))
	testing.SetOriginSend(coins(999999999))
	uassert.AbortsContains(t, cur, "directly from an account", func(cur realm) { Pay(cur, id) })
}

func TestTextValidation(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(barkeep))
	uassert.AbortsContains(t, cur, "not allowed", func(cur realm) { Open(cur, "[x](javascript:alert)") })
	uassert.AbortsContains(t, cur, "empty", func(cur realm) { Open(cur, "  ") })
	urequire.True(t, strings.Contains(Render(""), "Tab"))
	urequire.True(t, strings.HasPrefix(Render("json"), "{\"settledCents\":"))
}
