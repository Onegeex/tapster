package lastcall

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
	rep1   = testutils.TestAddress("rep1")
	rep2   = testutils.TestAddress("rep2")
	alice  = testutils.TestAddress("alice")
	bob    = testutils.TestAddress("bob")
	carol  = testutils.TestAddress("carol")
	dave   = testutils.TestAddress("dave")
	oracle = chain.PackageAddress("gno.land/r/tapsterns/tapster/v0")
	self   = chain.PackageAddress("gno.land/r/tapsterns/lastcall/v0")
	staked = false
	clock  int64 // blocks skipped so far; the test runner resets time between tests
)

func skip(n int64) {
	clock += n
	testing.SkipHeights(n)
}

// resume puts the chain clock back where the previous test left it.
func resume() { testing.SkipHeights(clock) }

func coins(n int64) chain.Coins { return chain.NewCoins(chain.NewCoin("ugnot", n)) }

func balance(a address) int64 { return banker.NewReadonlyBanker().GetCoins(a).AmountOf("ugnot") }

// publish makes Tapster finalize one GNOT-USD answer at price p and
// returns its round. Realm switching happens in this frame, which is
// also the frame that makes the calls.
func publish(cur realm, p int64) int64 {
	if !staked {
		testing.SetRealm(testing.NewUserRealm(rep1))
		testing.SetOriginSend(coins(1000000))
		testing.IssueCoins(oracle, coins(1000000))
		tapster.Stake(cross(cur), "rep1")
		testing.SetRealm(testing.NewUserRealm(rep2))
		testing.SetOriginSend(coins(1000000))
		testing.IssueCoins(oracle, coins(1000000))
		tapster.Stake(cross(cur), "rep2")
		staked = true
	}
	skip(61)
	testing.SetOriginSend(nil)
	testing.SetRealm(testing.NewUserRealm(rep1))
	tapster.Submit(cross(cur), "GNOT-USD", p)
	testing.SetRealm(testing.NewUserRealm(rep2))
	tapster.Submit(cross(cur), "GNOT-USD", p)
	skip(61)
	tapster.Finalize(cross(cur), "GNOT-USD")
	_, _, _, r, _ := tapster.Latest("GNOT-USD")
	return r
}

func stake(to address, n int64) {
	testing.SetOriginSend(coins(n))
	testing.IssueCoins(to, coins(n))
}

func TestFullGame(cur realm, t *testing.T) {
	resume()
	r := publish(cur, 50000)

	testing.SetRealm(testing.NewUserRealm(alice))
	stake(self, 2000000)
	uassert.Equal(t, r, Bet(cross(cur), "GNOT-USD", true))
	testing.SetRealm(testing.NewUserRealm(bob))
	stake(self, 1000000)
	Bet(cross(cur), "GNOT-USD", false)
	testing.SetRealm(testing.NewUserRealm(carol))
	stake(self, 1000000)
	Bet(cross(cur), "GNOT-USD", true)

	_, up, down, ok := Odds("GNOT-USD")
	uassert.True(t, ok)
	uassert.Equal(t, int64(3000000), up)
	uassert.Equal(t, int64(1000000), down)

	// Rules on betting.
	testing.SetRealm(testing.NewUserRealm(bob))
	stake(self, 1000000)
	uassert.AbortsContains(t, cur, "other way", func(cur realm) { Bet(cur, "GNOT-USD", true) })
	stake(self, 50000)
	uassert.AbortsContains(t, cur, "minimum bet", func(cur realm) { Bet(cur, "GNOT-USD", false) })
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/attacker/wrapper"))
	testing.SetOriginSend(coins(5000000))
	uassert.AbortsContains(t, cur, "directly from an account", func(cur realm) { Bet(cur, "GNOT-USD", true) })

	// Too early to settle.
	testing.SetRealm(testing.NewUserRealm(dave))
	testing.SetOriginSend(nil)
	uassert.AbortsContains(t, cur, "too early", func(cur realm) { Settle(cur, "GNOT-USD", r) })

	publish(cur, 50500)
	publish(cur, 51000) // now at least 3 rounds later, price went up

	testing.SetRealm(testing.NewUserRealm(dave))
	testing.SetOriginSend(nil)
	uassert.Equal(t, Up, Settle(cross(cur), "GNOT-USD", r))
	uassert.AbortsContains(t, cur, "already settled", func(cur realm) { Settle(cur, "GNOT-USD", r) })

	// Pot 4 GNOT, tip 0.5% = 0.02 GNOT to dave, 3.98 GNOT to UP bettors.
	uassert.Equal(t, int64(20000), balance(dave))
	uassert.Equal(t, int64(2653333), Owed("GNOT-USD", r, alice))
	uassert.Equal(t, int64(1326666), Owed("GNOT-USD", r, carol))
	uassert.Equal(t, int64(0), Owed("GNOT-USD", r, bob))

	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.Equal(t, int64(2653333), Claim(cross(cur), "GNOT-USD", r))
	uassert.Equal(t, int64(2653333), balance(alice))
	uassert.AbortsContains(t, cur, "already claimed", func(cur realm) { Claim(cur, "GNOT-USD", r) })
	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsContains(t, cur, "lost", func(cur realm) { Claim(cur, "GNOT-USD", r) })

	home := Render("")
	urequire.True(t, strings.Contains(home, "UP won"))
	urequire.True(t, strings.Contains(Render("player/"+alice.String()), "claimed 2.653 GNOT"))
	urequire.True(t, strings.Contains(Render("player/"+carol.String()), "[Claim 1.326 GNOT]"))
	urequire.True(t, strings.HasPrefix(Render("json"), "{\"games\":"))
}

func TestOneSidedRefund(cur realm, t *testing.T) {
	resume()
	r := publish(cur, 60000)
	testing.SetRealm(testing.NewUserRealm(alice))
	stake(self, 1000000)
	Bet(cross(cur), "GNOT-USD", true)
	publish(cur, 59000)
	publish(cur, 58000)
	testing.SetRealm(testing.NewUserRealm(dave))
	testing.SetOriginSend(nil)
	before := balance(dave)
	uassert.Equal(t, OneSided, Settle(cross(cur), "GNOT-USD", r))
	uassert.Equal(t, before, balance(dave)) // no tip on refunds
	uassert.Equal(t, int64(1000000), Owed("GNOT-USD", r, alice))
}

func TestTieRefund(cur realm, t *testing.T) {
	resume()
	r := publish(cur, 70000)
	testing.SetRealm(testing.NewUserRealm(alice))
	stake(self, 1000000)
	Bet(cross(cur), "GNOT-USD", true)
	testing.SetRealm(testing.NewUserRealm(bob))
	stake(self, 3000000)
	Bet(cross(cur), "GNOT-USD", false)
	publish(cur, 71000)
	publish(cur, 70000)
	testing.SetRealm(testing.NewUserRealm(carol))
	testing.SetOriginSend(nil)
	uassert.Equal(t, Tie, Settle(cross(cur), "GNOT-USD", r))
	uassert.Equal(t, int64(3000000), Owed("GNOT-USD", r, bob))
}

func TestExpiredRefund(cur realm, t *testing.T) {
	resume()
	r := publish(cur, 80000)
	testing.SetRealm(testing.NewUserRealm(alice))
	stake(self, 1000000)
	Bet(cross(cur), "GNOT-USD", true)
	testing.SetRealm(testing.NewUserRealm(bob))
	stake(self, 1000000)
	Bet(cross(cur), "GNOT-USD", false)
	for i := 0; i < 7; i++ {
		publish(cur, 90000)
	}
	testing.SetRealm(testing.NewUserRealm(carol))
	testing.SetOriginSend(nil)
	uassert.Equal(t, Unsettled, Settle(cross(cur), "GNOT-USD", r))
	uassert.Equal(t, int64(1000000), Owed("GNOT-USD", r, alice))
	uassert.Equal(t, int64(1000000), Owed("GNOT-USD", r, bob))
}

func TestStalePriceBlocksBets(cur realm, t *testing.T) {
	resume()
	publish(cur, 50000)
	skip(200) // 1000s: the latest answer is now stale
	testing.SetRealm(testing.NewUserRealm(alice))
	stake(self, 1000000)
	uassert.AbortsContains(t, cur, "stale", func(cur realm) { Bet(cur, "GNOT-USD", true) })
	uassert.AbortsContains(t, cur, "no price", func(cur realm) { Bet(cur, "ETH-USD", true) })
}

func TestMulDivNoOverflow(t *testing.T) {
	// Largest bet against the largest pot.
	uassert.Equal(t, int64(100000000), mulDiv(maxBet, maxPot, maxPot))
	uassert.Equal(t, int64(99500000), mulDiv(maxBet, 9950000000, maxPot))
	uassert.Equal(t, "1.99x", multiplier(1000000, 1000000))
	uassert.Equal(t, "3.98x", multiplier(1000000, 3000000))
}
