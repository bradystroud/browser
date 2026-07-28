import Foundation

/// A small, hand-curated, high-confidence starter block list -- ships with
/// the app so ad/tracker blocking works offline out of the box, without
/// requiring a remote list fetch first. Deliberately conservative: known
/// ad-serving/ad-tech/tracking-pixel infrastructure only, not comment/share
/// widgets or dual-use services (e.g. push-notification SDKs) that would
/// visibly break legitimate site functionality if blocked outright.
///
/// This is a *starter*, not a claim of comprehensive coverage -- loading a
/// full curated list (OISD, StevenBlack) via `BlockList.load(_:)` is the
/// intended primary path for real-world coverage; this only needs to get
/// the feature working the moment the app launches, before any remote list
/// has ever been fetched.
///
/// Plain domain-per-line format (see `ListParser`), with `#`-prefixed
/// section headers for maintainability -- also doubles as a live example of
/// the parser handling comments and plain-domain lines in the same text.
public let starterBlockListText = """
# Google / Alphabet ad-tech
doubleclick.net
googlesyndication.com
googleadservices.com
google-analytics.com
googletagmanager.com
googletagservices.com
adservice.google.com

# Meta / Facebook
connect.facebook.net
facebook.net

# Amazon ad tech
amazon-adsystem.com
assoc-amazon.com

# Microsoft / Bing / Clarity
ads.microsoft.com
bat.bing.com
clarity.ms

# Major independent ad exchanges / networks / DSPs / SSPs
adnxs.com
criteo.com
criteo.net
taboola.com
outbrain.com
scorecardresearch.com
comscore.com
quantserve.com
adsrvr.org
pubmatic.com
rubiconproject.com
openx.net
casalemedia.com
contextweb.com
adform.net
smartadserver.com
media.net
2mdn.net
serving-sys.com
adroll.com
bluekai.com
exelator.com
mathtag.com
turn.com
rlcdn.com
tapad.com
agkn.com
yieldmo.com
sharethrough.com
teads.tv
revcontent.com
mgid.com
popads.net
propellerads.com
exoclick.com
juicyads.com
zedo.com
indexexchange.com
sovrn.com
gumgum.com
triplelift.com
33across.com
bidswitch.net
smaato.com
adtelligent.com
freewheel.tv
fwmrm.net
spotxchange.com
springserve.com
innovid.com
undertone.com
simpli.fi
adzerk.net
bidtellect.com
yieldlab.net
smartyads.com
loopme.com
verve.com
fyber.com
adcash.com
clickadu.com
hilltopads.net
adsterra.com
popcash.net

# Ad verification / viewability
moatads.com
moat.com
adsafeprotected.com
doubleverify.com

# Mobile / in-app ad SDKs and attribution
inmobi.com
chartboost.com
vungle.com
applovin.com
unityads.unity3d.com
ironsrc.com
adcolony.com
flurry.com
mopub.com
appsflyer.com
adjust.com
kochava.com
tune.com
singular.net
pubnative.net
mobfox.com
startapp.com
airpush.com

# Web analytics / heatmaps / session replay (heavily tracker-listed)
hotjar.com
mixpanel.com
segment.com
segment.io
amplitude.com
fullstory.com
mouseflow.com
crazyegg.com
mparticle.com
heap.io
clicktale.net
chartbeat.com
imrworldwide.com
statcounter.com
histats.com
getclicky.com
woopra.com
kissmetrics.com
luckyorange.com
inspectlet.com
smartlook.com
"""
