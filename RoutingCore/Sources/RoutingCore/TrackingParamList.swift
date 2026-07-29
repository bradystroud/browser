import Foundation

/// A small, hand-curated, high-confidence starter list of known
/// tracking/analytics query-parameter names -- ships with the app so
/// tracking-param stripping works out of the box, without any remote list
/// fetch (browser-ymx). Same "starter, not a claim of comprehensive
/// coverage" framing as BlockListCore's `starterBlockListText`: this covers
/// the well-known, high-confidence cases (Google/Meta/Microsoft/TikTok/
/// email-platform campaign tracking, the common analytics-platform click
/// IDs), not an exhaustive registry.
///
/// One entry per line, `#`-prefixed section headers, blank lines ignored --
/// same plain-text format as `starterBlockListText`. An entry ending in `*`
/// is a *prefix* match (`utm_*` matches `utm_source`, `utm_campaign`, any
/// future `utm_`-prefixed key Google adds); everything else is an exact,
/// case-insensitive match against a query parameter's name (not its
/// value). See `TrackingParamStripper` for how this text is parsed and
/// applied.
public let starterTrackingParamsText = """
# Google Ads / Analytics (utm_* covers the whole family, current and future)
utm_*
gclid
gclsrc
dclid
gbraid
wbraid
srsltid
_ga
_gl

# Meta / Facebook / Instagram
fbclid
fb_action_ids
fb_action_types
fb_ref
fb_source
igshid
igsh

# Microsoft / Bing / Clarity
msclkid

# TikTok
ttclid

# Twitter / X
twclid

# LinkedIn
li_fat_id

# Snapchat
sccid

# Pinterest
epik

# Reddit
rdt_cid

# Yandex
yclid

# HubSpot
_hsenc
_hsmi
hsCtaTracking
hsa_acc
hsa_ad
hsa_net
hsa_src
hsa_tgt
hsa_kw
hsa_grp
hsa_mt
hsa_cam
hsa_ver

# Marketo
mkt_tok

# Vero
vero_id
vero_conv

# Mailchimp
mc_cid
mc_eid

# Klaviyo
_kx

# Adobe / Omniture / SiteCatalyst
icid
s_cid
sc_cid

# Matomo / Piwik
pk_campaign
pk_kwd
pk_source
pk_medium
piwik_campaign
piwik_kwd

# Webtrends
wt.mc_id
wt.mc_ev
wtrid

# Oracle Eloqua
elqTrackId
elq
elqat

# Cxense / Sitecore Send
sc_channel
sc_content
sc_medium
sc_outcome
sc_geo
sc_country

# Olytics
oly_enc_id
oly_anon_id

# Affiliate / display-ad click IDs
irclickid
irgwc
affiliate_id
aff_id
cmpid
campaign_id
ad_id
adgroupid
adset_id

# Generic campaign/referral params seen across many platforms
ref
ref_src
refsrc
spm
scid
si
ftag
trk
trkCampaign
"""
