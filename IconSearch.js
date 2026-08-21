.pragma library

// macOSicons search API contract shared by the QML picker and the CLI helper.
// The helper's `search` subcommand prints an array shaped like parseResponse()
// expects, so the picker and the tests exercise one data shape.

function buildSearchRequest(query) {
    return {
        url: "https://macosicons.com/api/search",
        body: JSON.stringify({
            query: String(query || ""),
            searchOptions: { filters: [], hitsPerPage: 24, page: 1, sort: ["downloads:desc"] }
        })
    }
}

function parseResponse(text) {
    var parsed = []
    try {
        parsed = JSON.parse(String(text || ""))
    } catch (error) {
        return []
    }
    if (!Array.isArray(parsed)) return []
    var results = []
    parsed.forEach(function(item) {
        if (!item || !item.iOSUrl) return
        results.push({
            appName: String(item.appName || ""),
            appSlug: String(item.appSlug || ""),
            objectID: String(item.objectID || ""),
            iOSUrl: String(item.iOSUrl || ""),
            lowResPngUrl: String(item.lowResPngUrl || ""),
            downloads: Number(item.downloads || 0)
        })
    })
    return results
}

// The icon page slug used by macosicons.com URLs (/icon/<slug>-<objectID>).
// Kept for display/linking; downloads use iOSUrl directly.
function pageUrl(item) {
    if (!item) return ""
    var name = String(item.appName || "").toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "")
    var id = String(item.objectID || "")
    if (!name || !id) return ""
    return "https://macosicons.com/icon/" + name + "-" + id
}

function fileUrlToPath(url) {
    return decodeURIComponent(String(url || "").replace(/^file:\/\//, ""))
}

if (typeof module !== "undefined" && module.exports) {
    module.exports = {
        buildSearchRequest: buildSearchRequest,
        parseResponse: parseResponse,
        pageUrl: pageUrl,
        fileUrlToPath: fileUrlToPath
    }
}