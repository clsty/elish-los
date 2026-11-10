# NTP and captive portal, independent of the system language

## The problem

The device tree already carried CN-friendly addresses - Aliyun NTP and MIUI's
`generate_204` probe - but they lived under `values-zh-rCN/`. So they took effect **only when
the system language was Chinese**. Set English and the platform fell back to
`time.android.com` and `connectivitycheck.gstatic.com`, neither of which answers promptly
here: the clock stays at whatever the build epoch says until something else corrects it, and
every network gets flagged as possibly captive.

The system language is the user's to change; network addresses should not follow it. So the
change is to the **condition, not the values**: the same resources move to the untranslated
`values/` directory.

## The model, and the trap that comes with it

Two overlays, two resources, two readers. Overriding the *wrong* resource name fails
silently, which is why the readers were checked in source first:

| Resource | Reader | Overlay package |
| --- | --- | --- |
| `config_ntpServers` | `frameworks/base/.../android/util/NtpTrustedTime.java`, reading `com.android.internal.R.array.config_ntpServers` | `android` → `FrameworkResOverlayElish` |
| `config_captive_portal_http_url` / `_https_url` | the Connectivity module's own resources | `com.android.networkstack` → `NetworkStackOverlayMIUI` |

The two names in the last column are the source directory and the installed package, and the
criteria below grep the installed names: `FrameworkResOverlayElish` installs as
`android.framework_res.overlay.elish`, `NetworkStackOverlayMIUI` as
`com.android.networkstack.overlay.miui` (both read from the overlay's own manifest).

One detail in `patches/apply-cn-network-changes.sh` is worth knowing before changing it: the
overlay `NetworkStackOverlayMIUI` had **no** `values/config.xml` at all, only the localized
one. The script creates the file (carrying over the license header from the old file) instead
of requiring it to exist. And the old `values-zh-rCN/config.xml` is deleted after the move,
because leaving it would leave a second truth for the same resource.

## Criteria

```sh
adb shell 'cmd overlay list' | grep -E "android.framework_res.overlay.elish|com.android.networkstack.overlay.miui"
# expect both marked [x]

adb shell settings get global captive_portal_http_url     # expect null
adb shell settings get global captive_portal_https_url    # expect null
```

`null` is the required reading, not an absence of configuration: a value in
`Settings.Global` is a **user-level override** that shadows the config default, so the
overlay would look enabled while nothing uses it.

Then the two behavioural checks - both need an actual network connection, and both are
"do not judge if the precondition is missing":

```sh
adb shell dumpsys network_stack | grep -oE "https?://[A-Za-z0-9._/-]*generate_204" | sort -u
# expect http://connect.rom.miui.com/generate_204

adb shell dumpsys time_detector | grep -iE "ntp|Network suggestion|systemClockConfidence"
# expect the suggestion history to name ntp.aliyun.com, and systemClockConfidence() != 0
```

The probe belongs to **`network_stack`, not `connectivity`**: on this Android version the NetworkStack
service owns it, and `dumpsys connectivity` holds no `generate_204` and no `captive`/`portal` line at
all (measured 2026-11-10). Grepping the wrong service returns nothing, which looks exactly like a
missing endpoint. `dumpsys network_stack` also carries the probe's own result -
`PROBE_HTTP http://connect.rom.miui.com/generate_204 ... ret=204` - which is the stronger evidence.

With no default route (`ip route` shows none), the expected readings are
`Network suggestion history: {Empty}` and `systemClockConfidence()=0`. Those are an unmet
precondition, not a failure. A quick reachability probe separates the two cases:

```sh
adb shell ping -c 1 -W 3 connect.rom.miui.com
adb shell ping -c 1 -W 3 ntp.aliyun.com
```

Both addresses are also worth testing once with the system language set to English, which is
the whole point of the change.
