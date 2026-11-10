# Horizon theme

The native dashboard uses adaptive `dsHorizon*` colors, paired daytime/nighttime
landscape assets, rounded system headings, simple score rings and opaque tonal
cards. Theme changes resolve through dynamic UIColor providers and asset
appearance variants without replacing navigation or server-owned content.

Shared cards add outlines for Increased Contrast and use a solid surface for
Reduce Transparency. Scrolling content remains clipped below system chrome;
one stationary scene extends behind the safe area. Trends uses a shorter scene.

The Russian caption of the Today sleep ring is shortened to `Сон`; accessibility
and the Sleep screen retain the full metric name. Sleep structure is one 24-point
capsule without gaps, preserving the original durations, proportions and colors.

## Canonical tokens

[The additive canonical patch](design-system/horizon-tokens.patch) applies to the
`dzarlax/design-system` repository at `906a7a197590699858d7f72804cafedcbcdcf627`.
It adds 21 Horizon roles, their generator mappings and generated Swift output.
Existing shared token values and generated CSS are unchanged. The app mirrors
the generated Horizon declarations and retains its existing color helpers.

The patch was prepared and verified in an isolated clean checkout because the
original design-system checkout contains unrelated local edits. It has not been
merged into the upstream design-system repository.

## Verification

HorizonThemeTests checks text/surface contrast, gauge/track contrast, dynamic
colors, paired assets and sampled scene composition under the adaptive veil.
HorizonAppearanceUITests checks the short/full Russian captions, both themes,
Sleep structure and the last Trends row above the floating tab bar.

Runtime checks covered iPhone 17 Pro and iPhone 17 on iOS 26.5, live system theme
changes, Increased Contrast, Reduce Transparency and Reduce Motion. Existing
insight, chart, metric-navigation and large-text tests cover the presentation
paths. Physical-device acceptance, spoken VoiceOver, minimum 375-point width and
instrumented performance measurements were not performed.

Before the release commit, all 143 unit tests and 29 affected UI tests passed
on iPhone 17 Pro / iOS 26.5 (172 total, no failures or skips).
