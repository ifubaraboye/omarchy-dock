.pragma library

var FALLBACK_MAP = {
    "org.kde.dolphin": "system-file-manager",
    "dolphin": "system-file-manager",
    "code": "vscode",
    "com.visualstudio.code": "vscode",
    "google-chrome": "google-chrome",
    "com.google.Chrome": "google-chrome",
    "whatsapp": "WhatsApp",
    "discord": "Discord",
    "omarchy-discord": "Discord"
}

function sanitizeName(value) {
    return String(value || "").replace(/\.desktop$/i, "").replace(/[-_]+/g, " ").trim()
}

function normalizeId(value) {
    var id = String(value || "").trim()
    return id.endsWith(".desktop") ? id.slice(0, -8) : id
}

function customIconFile(customIcons, id) {
    var key = normalizeId(id)
    var value = customIcons && customIcons[key]
    if (!value && customIcons) {
        var lowerKey = key.toLowerCase()
        for (var candidate in customIcons) {
            var normalizedCandidate = normalizeId(candidate)
            if (normalizedCandidate.toLowerCase() === lowerKey) {
                value = customIcons[candidate]
                break
            }
        }
        // Web apps often run with a generated Chrome/Helium class such as
        // chrome-web.whatsapp.com__-Default rather than WhatsApp.desktop.
        if (!value && lowerKey.length >= 4) {
            for (var alias in customIcons) {
                var normalizedAlias = normalizeId(alias).toLowerCase()
                if (lowerKey.indexOf(normalizedAlias) !== -1) {
                    value = customIcons[alias]
                    break
                }
            }
        }
    }
    if (!value) return ""
    var file = typeof value === "string" ? value : value.file
    file = String(file || "").trim()
    return /^[A-Za-z0-9._-]+$/.test(file) ? file : ""
}

function resolveIcon(item) {
    var data = item || {}
    var icon = String(data.icon || data.iconName || "").trim()
    if (icon) return icon

    var id = normalizeId(data.id || data.desktopId)
    if (FALLBACK_MAP[id]) return FALLBACK_MAP[id]

    var lower = id.toLowerCase()
    for (var key in FALLBACK_MAP) {
        if (key.toLowerCase() === lower) return FALLBACK_MAP[key]
    }
    return "application-x-executable"
}

if (typeof module !== "undefined" && module.exports) {
    module.exports = {
        FALLBACK_MAP: FALLBACK_MAP,
        sanitizeName: sanitizeName,
        normalizeId: normalizeId,
        customIconFile: customIconFile,
        resolveIcon: resolveIcon
    }
}
