package tapster

import (
	"chain"
	"strings"
	"testing"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
	"gno.land/p/nt/urequire/v0"
)

var (
	adminAddr = testutils.TestAddress("admin")
	alice     = testutils.TestAddress("alice")
	bob       = testutils.TestAddress("bob")
	carol     = testutils.TestAddress("carol")
	mallory   = testutils.TestAddress("mallory")
	realmAddr = chain.PackageAddress("gno.land/r/tapsterns/tapster/v0")
)

func ugnotCoins(n int64) chain.Coins { return chain.NewCoins(chain.NewCoin("ugnot", n)) }

// attach sets the coins sent with the next call and credits the realm,
// because the test VM does not move -send coins. The caller itself must be
// set with testing.SetRealm in the test function's own frame.
func withSend(send int64) {
	if send > 0 {
		testing.SetOriginSend(ugnotCoins(send))
		testing.IssueCoins(realmAddr, ugnotCoins(send))
	} else {
		testing.SetOriginSend(nil)
	}
}

func resetState() {
	admin = adminAddr
	reporters = avl.NewTree()
	events = nil
	totalSlashed = 0
	totalRewards = 0
	feeds.Iterate("", "", func(_ string, v any) bool {
		f := v.(*Feed)
		f.current = nil
		f.latest = Answer{}
		f.hasAnswer = false
		f.history = nil
		f.lastReports = nil
		f.Pool = 0
		f.MinReports = 2
		f.RoundSecs = 60
		f.ToleranceBps = 100
		f.OutlierBps = 500
		f.SlashBps = 500
		f.RewardPerReport = 2000
		f.Paused = false
		return false
	})
	minStake = 1000000
	unbondingSecs = 3600
}

// nextRound moves time past the current round (blocks are 5s in tests).
func nextRound() { testing.SkipHeights(13) }

func TestDefaultFeeds(cur realm, t *testing.T) {
	resetState()
	uassert.Equal(t, "BTC-USD,ETH-USD,GNOT-USD,XAU-USD", Pairs())
	_, dec, _, _, ok := Latest("GNOT-USD")
	uassert.False(t, ok)
	uassert.Equal(t, 6, dec)
}

func TestStakeRules(cur realm, t *testing.T) {
	resetState()

	testing.SetRealm(testing.NewUserRealm(alice))
	withSend(500000)
	uassert.AbortsContains(t, cur, "at least", func(cur realm) { Stake(cur, "alice") })

	testing.SetRealm(testing.NewUserRealm(alice))
	withSend(1000000)
	urequire.NotAborts(t, cur, func(cur realm) { Stake(cur, "alice") })
	s, _, active := ReporterStake(alice)
	uassert.Equal(t, int64(1000000), s)
	uassert.True(t, active)

	// Top up without renaming.
	testing.SetRealm(testing.NewUserRealm(alice))
	withSend(250000)
	Stake(cross(cur), "")
	s, _, _ = ReporterStake(alice)
	uassert.Equal(t, int64(1250000), s)
	uassert.Equal(t, "alice", getReporter(alice).Name)

	testing.SetRealm(testing.NewUserRealm(bob))
	withSend(1000000)
	uassert.AbortsContains(t, cur, "name may only use", func(cur realm) { Stake(cur, "<script>") })
}

// A code realm in the middle could take the -send coins and then call
// Stake; the IsUserCall guard must reject that.
func TestStakeRejectsCodeRealmCaller(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/attacker/wrapper"))
	testing.SetOriginSend(ugnotCoins(5000000))
	uassert.AbortsContains(t, cur, "directly from an account", func(cur realm) { Stake(cur, "evil") })
}

func TestRoundMedianRewardsAndSlash(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(alice))
	withSend(2000000)
	Stake(cross(cur), "alice")
	testing.SetRealm(testing.NewUserRealm(bob))
	withSend(2000000)
	Stake(cross(cur), "bob")
	testing.SetRealm(testing.NewUserRealm(carol))
	withSend(2000000)
	Stake(cross(cur), "carol")
	testing.SetRealm(testing.NewUserRealm(mallory))
	withSend(10000000)
	Fund(cross(cur), "GNOT-USD")
	uassert.Equal(t, int64(10000000), mustFeed("GNOT-USD").Pool)

	nextRound()
	testing.SetRealm(testing.NewUserRealm(alice))
	withSend(0)
	Submit(cross(cur), "GNOT-USD", 60000)
	testing.SetRealm(testing.NewUserRealm(bob))
	withSend(0)
	Submit(cross(cur), "GNOT-USD", 60300) // 0.5% off: accurate
	testing.SetRealm(testing.NewUserRealm(carol))
	withSend(0)
	Submit(cross(cur), "GNOT-USD", 90000) // 50% off: outlier

	testing.SetRealm(testing.NewUserRealm(alice))
	withSend(0)
	uassert.AbortsContains(t, cur, "already reported", func(cur realm) { Submit(cur, "GNOT-USD", 60000) })

	nextRound()
	testing.SetRealm(testing.NewUserRealm(bob))
	withSend(0)
	uassert.True(t, Finalize(cross(cur), "GNOT-USD"))

	price, dec, _, _, ok := Latest("GNOT-USD")
	uassert.True(t, ok)
	uassert.Equal(t, 6, dec)
	uassert.Equal(t, int64(60300), price) // equal stakes: lower middle of 3 is the middle

	a := getReporter(alice)
	b := getReporter(bob)
	c := getReporter(carol)
	uassert.Equal(t, 1, a.Accurate)
	uassert.Equal(t, 1, b.Accurate)
	uassert.Equal(t, int64(2000), a.Rewards)
	uassert.Equal(t, 1, c.Outliers)
	uassert.Equal(t, int64(100000), c.Slashed) // 5% of 2 GNOT
	uassert.Equal(t, int64(1900000), c.Stake)
	// pool: 10 GNOT - 2*0.002 + 0.1 slashed
	uassert.Equal(t, int64(10000000-4000+100000), mustFeed("GNOT-USD").Pool)

	urequire.True(t, strings.Contains(renderActivity(), "slashed"))
	urequire.True(t, strings.Contains(renderFeed("GNOT-USD"), "🔪 slashed"))

	// Second Finalize is a no-op.
	uassert.False(t, Finalize(cross(cur), "GNOT-USD"))
}

func TestStakeWeightBeatsCheapLiars(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(alice))
	withSend(10000000) // honest, heavy
	Stake(cross(cur), "alice")
	testing.SetRealm(testing.NewUserRealm(bob))
	withSend(1000000)
	Stake(cross(cur), "bob")
	testing.SetRealm(testing.NewUserRealm(carol))
	withSend(1000000)
	Stake(cross(cur), "carol")

	nextRound()
	testing.SetRealm(testing.NewUserRealm(alice))
	withSend(0)
	Submit(cross(cur), "BTC-USD", 91000000000)
	testing.SetRealm(testing.NewUserRealm(bob))
	withSend(0)
	Submit(cross(cur), "BTC-USD", 50000000000)
	testing.SetRealm(testing.NewUserRealm(carol))
	withSend(0)
	Submit(cross(cur), "BTC-USD", 50000000000)
	nextRound()
	Finalize(cross(cur), "BTC-USD")

	price, _, _, _, _ := Latest("BTC-USD")
	uassert.Equal(t, int64(91000000000), price)
	uassert.Equal(t, 1, getReporter(bob).Outliers)
	uassert.Equal(t, 1, getReporter(carol).Outliers)
}

func TestNoQuorum(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(alice))
	withSend(2000000)
	Stake(cross(cur), "alice")
	testing.SetRealm(testing.NewUserRealm(bob))
	withSend(2000000)
	Stake(cross(cur), "bob")
	testing.SetRealm(testing.NewUserRealm(carol))
	withSend(2000000)
	Stake(cross(cur), "carol")
	nextRound()
	testing.SetRealm(testing.NewUserRealm(alice))
	withSend(0)
	Submit(cross(cur), "ETH-USD", 3000000000)
	nextRound()
	Finalize(cross(cur), "ETH-USD")
	_, _, _, _, ok := Latest("ETH-USD")
	uassert.False(t, ok)
	uassert.Equal(t, 1, mustFeed("ETH-USD").roundsMissed)
}

func TestNewRoundFinalizesPrevious(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(alice))
	withSend(2000000)
	Stake(cross(cur), "alice")
	testing.SetRealm(testing.NewUserRealm(bob))
	withSend(2000000)
	Stake(cross(cur), "bob")
	testing.SetRealm(testing.NewUserRealm(carol))
	withSend(2000000)
	Stake(cross(cur), "carol")
	nextRound()
	testing.SetRealm(testing.NewUserRealm(alice))
	withSend(0)
	Submit(cross(cur), "XAU-USD", 2650000000)
	testing.SetRealm(testing.NewUserRealm(bob))
	withSend(0)
	Submit(cross(cur), "XAU-USD", 2651000000)
	nextRound()
	testing.SetRealm(testing.NewUserRealm(carol))
	withSend(0)
	Submit(cross(cur), "XAU-USD", 2652000000) // first report of new round closes the old one
	price, _, _, _, ok := Latest("XAU-USD")
	uassert.True(t, ok)
	uassert.Equal(t, int64(2650000000), price) // lower middle of two equal-weight reports
	uassert.Equal(t, 1, len(mustFeed("XAU-USD").current.Reports))
}

func TestFreshness(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(alice))
	withSend(2000000)
	Stake(cross(cur), "alice")
	testing.SetRealm(testing.NewUserRealm(bob))
	withSend(2000000)
	Stake(cross(cur), "bob")
	testing.SetRealm(testing.NewUserRealm(carol))
	withSend(2000000)
	Stake(cross(cur), "carol")
	nextRound()
	testing.SetRealm(testing.NewUserRealm(alice))
	withSend(0)
	Submit(cross(cur), "GNOT-USD", 61000)
	testing.SetRealm(testing.NewUserRealm(bob))
	withSend(0)
	Submit(cross(cur), "GNOT-USD", 61000)
	nextRound()
	Finalize(cross(cur), "GNOT-USD")

	p, _, ok := PriceFresh("GNOT-USD", 600)
	uassert.True(t, ok)
	uassert.Equal(t, int64(61000), p)

	testing.SkipHeights(200) // 1000s later
	_, _, ok = PriceFresh("GNOT-USD", 600)
	uassert.False(t, ok)
	uassert.PanicsContains(t, cur, "no fresh price", func() { MustPriceFresh("GNOT-USD", 600) })
}

func TestExitAndWithdraw(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(alice))
	withSend(2000000)
	Stake(cross(cur), "alice")
	testing.SetRealm(testing.NewUserRealm(bob))
	withSend(2000000)
	Stake(cross(cur), "bob")
	testing.SetRealm(testing.NewUserRealm(carol))
	withSend(2000000)
	Stake(cross(cur), "carol")

	nextRound()
	testing.SetRealm(testing.NewUserRealm(carol))
	withSend(0)
	Submit(cross(cur), "GNOT-USD", 99999) // will be an outlier
	testing.SetRealm(testing.NewUserRealm(alice))
	withSend(0)
	Submit(cross(cur), "GNOT-USD", 60000)
	testing.SetRealm(testing.NewUserRealm(bob))
	withSend(0)
	Submit(cross(cur), "GNOT-USD", 60000)

	testing.SetRealm(testing.NewUserRealm(carol))
	withSend(0)
	RequestExit(cross(cur))
	uassert.AbortsContains(t, cur, "reporter is exiting", func(cur realm) { Submit(cur, "BTC-USD", 1) })
	uassert.AbortsContains(t, cur, "unbonding", func(cur realm) { Withdraw(cur) })

	// Unbonding is long over, but the round holding carol's bad report was
	// never finalized: Withdraw must judge it before paying out.
	testing.SkipHeights(800)
	testing.SetRealm(testing.NewUserRealm(carol))
	withSend(0)
	Withdraw(cross(cur))
	uassert.True(t, getReporter(carol) == nil)
	uassert.Equal(t, int64(100000), totalSlashed)
}

func TestWithdrawBlockedByOpenRound(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(alice))
	withSend(2000000)
	Stake(cross(cur), "alice")
	testing.SetRealm(testing.NewUserRealm(bob))
	withSend(2000000)
	Stake(cross(cur), "bob")
	testing.SetRealm(testing.NewUserRealm(carol))
	withSend(2000000)
	Stake(cross(cur), "carol")
	nextRound()
	testing.SetRealm(testing.NewUserRealm(carol))
	withSend(0)
	Submit(cross(cur), "GNOT-USD", 1)
	RequestExit(cross(cur))
	getReporter(carol).ExitAt = now() // pretend unbonding is over
	uassert.AbortsContains(t, cur, "open round", func(cur realm) { Withdraw(cur) })
}

func TestClaimRewards(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(alice))
	withSend(2000000)
	Stake(cross(cur), "alice")
	testing.SetRealm(testing.NewUserRealm(bob))
	withSend(2000000)
	Stake(cross(cur), "bob")
	testing.SetRealm(testing.NewUserRealm(carol))
	withSend(2000000)
	Stake(cross(cur), "carol")
	testing.SetRealm(testing.NewUserRealm(mallory))
	withSend(1000000)
	Fund(cross(cur), "GNOT-USD")
	nextRound()
	testing.SetRealm(testing.NewUserRealm(alice))
	withSend(0)
	Submit(cross(cur), "GNOT-USD", 60000)
	testing.SetRealm(testing.NewUserRealm(bob))
	withSend(0)
	Submit(cross(cur), "GNOT-USD", 60000)
	nextRound()
	Finalize(cross(cur), "GNOT-USD")
	testing.SetRealm(testing.NewUserRealm(alice))
	withSend(0)
	ClaimRewards(cross(cur))
	uassert.Equal(t, int64(0), getReporter(alice).Rewards)
	uassert.Equal(t, int64(2000), getReporter(alice).Earned)
	uassert.AbortsContains(t, cur, "no rewards", func(cur realm) { ClaimRewards(cur) })
}

func TestAdminOnly(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(mallory))
	withSend(0)
	uassert.AbortsContains(t, cur, "admin only", func(cur realm) { AddFeed(cur, "SOL-USD", "", 6, 60, 2) })
	uassert.AbortsContains(t, cur, "admin only", func(cur realm) { SetPaused(cur, "GNOT-USD", true) })
	uassert.AbortsContains(t, cur, "admin only", func(cur realm) { TransferAdmin(cur, mallory) })

	testing.SetRealm(testing.NewUserRealm(adminAddr))
	withSend(0)
	AddFeed(cross(cur), "SOL-USD", "Solana", 6, 30, 1)
	uassert.True(t, strings.Contains(Pairs(), "SOL-USD"))
	uassert.AbortsContains(t, cur, "slashBps", func(cur realm) {
		SetFeedParams(cur, "SOL-USD", 30, 1, 100, 500, 5000, 0) // 50% slash refused
	})
	uassert.AbortsContains(t, cur, "toleranceBps", func(cur realm) {
		SetFeedParams(cur, "SOL-USD", 30, 1, 600, 500, 100, 0)
	})
	uassert.AbortsContains(t, cur, "may only use", func(cur realm) { AddFeed(cur, "sol/usd", "", 6, 60, 1) })

	SetPaused(cross(cur), "SOL-USD", true)
	testing.SetRealm(testing.NewUserRealm(alice))
	withSend(2000000)
	Stake(cross(cur), "alice")
	testing.SetRealm(testing.NewUserRealm(bob))
	withSend(2000000)
	Stake(cross(cur), "bob")
	testing.SetRealm(testing.NewUserRealm(carol))
	withSend(2000000)
	Stake(cross(cur), "carol")
	testing.SetRealm(testing.NewUserRealm(alice))
	withSend(0)
	uassert.AbortsContains(t, cur, "paused", func(cur realm) { Submit(cur, "SOL-USD", 150000000) })
}

func TestRenderPages(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(alice))
	withSend(2000000)
	Stake(cross(cur), "alice")
	testing.SetRealm(testing.NewUserRealm(bob))
	withSend(2000000)
	Stake(cross(cur), "bob")
	testing.SetRealm(testing.NewUserRealm(carol))
	withSend(2000000)
	Stake(cross(cur), "carol")
	for i := 0; i < 3; i++ {
		nextRound()
		testing.SetRealm(testing.NewUserRealm(alice))
	withSend(0)
		Submit(cross(cur), "GNOT-USD", 60000+int64(i)*100)
		testing.SetRealm(testing.NewUserRealm(bob))
	withSend(0)
		Submit(cross(cur), "GNOT-USD", 60050+int64(i)*100)
	}
	nextRound()
	Finalize(cross(cur), "GNOT-USD")

	home := Render("")
	urequire.True(t, strings.Contains(home, "Tapster"))
	urequire.True(t, strings.Contains(home, "$0.060"))
	urequire.True(t, strings.Contains(home, "data:image/svg+xml;base64,"))
	urequire.True(t, strings.Contains(Render("feed/GNOT-USD"), "price chart"))
	urequire.True(t, strings.Contains(Render("reporters"), "alice"))
	urequire.True(t, strings.Contains(Render("integrate"), "MustPriceFresh"))
	urequire.True(t, strings.Contains(Render("feed/BTC-USD"), "Parameters"))
	uassert.Equal(t, "$91,000,000.00", displayPrice(mustFeed("BTC-USD"), 91000000000000))
	uassert.Equal(t, "$999.50", displayPrice(mustFeed("BTC-USD"), 999500000))
	uassert.Equal(t, "$0.060000", displayPrice(mustFeed("BTC-USD"), 60000))
	j := Render("json/GNOT-USD")
	urequire.True(t, strings.HasPrefix(j, "{\"pair\":\"GNOT-USD\""))
	urequire.True(t, strings.Contains(j, "\"history\":[["))
	urequire.True(t, strings.Contains(Render("json"), "\"feeds\":["))
	urequire.True(t, strings.Contains(Render("json/reporters"), "\"name\":\"alice\""))
	urequire.True(t, strings.Contains(Render("nope"), "404"))
	uassert.Equal(t, 3, len(strings.Split(History("GNOT-USD", 0), ",")))
}

func TestRegisterConsumer(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "only realms", func(cur realm) { RegisterConsumer(cur, "x") })
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/demo/shop"))
	RegisterConsumer(cross(cur), "prices in USD")
	uassert.True(t, strings.Contains(Consumers(), "gno.land/r/demo/shop"))
	urequire.True(t, strings.Contains(Render(""), "prices in USD"))
}
