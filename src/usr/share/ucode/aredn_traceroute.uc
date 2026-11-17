/*
 * AREDN traceroute with per-hop mesh metadata (GPS, link type, Babel cost).
 * Side-loaded package companion for AREDN firmware.
 *
 * Attribution: AREDN project patterns and APIs.
 */

import * as fs from "fs";
import * as uci from "uci";
import * as babel from "aredn.babel";
import * as configuration from "aredn.configuration";
import * as mesh from "aredn.mesh";

const UFETCH = "/bin/uclient-fetch";
const FETCH_TIMEOUT = 2;

function toNum(v)
{
    if (v == null || v === "") {
        return null;
    }
    const n = +v;
    if (n != n) {
        return null;
    }
    return n;
}

function meshHost(name)
{
    if (!name || name === "*") {
        return null;
    }
    if (match(name, /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/)) {
        return name;
    }
    if (!match(name, /\./)) {
        return `${name}.local.mesh`;
    }
    return name;
}

function mapLinkType(type)
{
    if (!type) {
        return null;
    }
    switch (type) {
        case "DtD":
        case "DTD":
            return "DtD";
        case "RF":
        case "RRF":
        case "LRF":
            return "RF";
        case "Wireguard":
        case "WIREGUARD":
        case "WG":
            return "WG";
        case "Xlink":
        case "XLINK":
            return "Xlink";
        default:
            return type;
    }
}

function trackerIps(tracker)
{
    const ips = [];
    if (tracker.ip) {
        push(ips, tracker.ip);
    }
    if (tracker.canonical_ip && tracker.canonical_ip !== tracker.ip) {
        push(ips, tracker.canonical_ip);
    }
    return ips;
}

function indexTrackers(trackers)
{
    const byIp = {};
    const byHost = {};
    if (!trackers) {
        return { byIp: byIp, byHost: byHost };
    }
    for (let mac in trackers) {
        const t = trackers[mac];
        if (!t) {
            continue;
        }
        const ips = trackerIps(t);
        for (let i = 0; i < length(ips); i++) {
            byIp[ips[i]] = t;
        }
        if (t.hostname) {
            byHost[lc(t.hostname)] = t;
            const short = match(t.hostname, /^([^.]+)/);
            if (short) {
                byHost[lc(short[1])] = t;
            }
        }
    }
    return { byIp: byIp, byHost: byHost };
}

function findNeighbor(entry, nextIp, nextHost)
{
    if (!entry || entry.failed) {
        return null;
    }
    if (nextIp && entry.byIp[nextIp]) {
        return entry.byIp[nextIp];
    }
    if (nextHost) {
        const h = lc(replace(nextHost, /\.local\.mesh$/, ""));
        if (entry.byHost[h]) {
            return entry.byHost[h];
        }
        if (entry.byHost[lc(nextHost)]) {
            return entry.byHost[lc(nextHost)];
        }
    }
    return null;
}

function hasCostValue(v)
{
    return v != null && v !== "";
}

/**
 * Link costs and quality from previous-hop LQM (same fields as neighbor-device UI).
 * tx success = rev_lq, rx success = lq, neighbor errors = 100 - rev_quality.
 */
function linkStats(tracker)
{
    if (!tracker) {
        return {
            txcost: null,
            rxcost: null,
            txSuccess: null,
            rxSuccess: null,
            neighborErrors: null
        };
    }
    let neighborErrors = null;
    if (hasCostValue(tracker.rev_quality)) {
        neighborErrors = 100 - tracker.rev_quality;
    }
    return {
        txcost: hasCostValue(tracker.txcost) ? tracker.txcost : null,
        rxcost: hasCostValue(tracker.rxcost) ? tracker.rxcost : null,
        txSuccess: hasCostValue(tracker.rev_lq) ? tracker.rev_lq : null,
        rxSuccess: hasCostValue(tracker.lq) ? tracker.lq : null,
        neighborErrors: neighborErrors
    };
}

/**
 * Build dest-IP -> Babel path metric map from the local routing table.
 * LQM tracker.metric is often unset (nexthop matching uses IPv6 LL), so traceroute
 * metrics come from installed host routes to each hop address instead.
 */
function seedLocalRouteMetrics(ctx)
{
    ctx.routeMetricByIp = {};
    try {
        const routes = babel.getHostRoutes();
        for (let i = 0; i < length(routes); i++) {
            const r = routes[i];
            if (!r || r.metric == null || r.metric === 65535) {
                continue;
            }
            let dst = r.dst;
            const slash = match(dst, /^([^/]+)/);
            if (slash) {
                dst = slash[1];
            }
            if (match(dst, /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/)) {
                const prev = ctx.routeMetricByIp[dst];
                if (prev == null || r.metric < prev) {
                    ctx.routeMetricByIp[dst] = r.metric;
                }
            }
        }
    }
    catch (_) {
    }
}

function localPathMetric(ctx, ip)
{
    if (!ip || !ctx.routeMetricByIp) {
        return null;
    }
    const m = ctx.routeMetricByIp[ip];
    return m != null ? m : null;
}

/**
 * Path metric from this node (traceroute source) to the hop.
 * Prefer local Babel host routes; LQM neighbor.metric is unreliable (often null
 * due to IPv6 LL nexthops) and means "best route via neighbor", not "to hop".
 */
function resolvePathMetric(ctx, hop, node)
{
    let metric = localPathMetric(ctx, hop.ip);
    if (metric != null) {
        return {
            metric: metric,
            reason: null,
            source: "local_route"
        };
    }
    if (node && node.ip && node.ip !== hop.ip) {
        metric = localPathMetric(ctx, node.ip);
        if (metric != null) {
            return {
                metric: metric,
                reason: null,
                source: "local_route_mesh_ip"
            };
        }
    }
    const tried = hop.ip || "?";
    const mesh = (node && node.ip && node.ip !== hop.ip) ? ` or mesh IP ${node.ip}` : "";
    return {
        metric: null,
        reason: `no Babel host route on this node to ${tried}${mesh}`,
        source: null
    };
}

export function createContext()
{
    return {
        byKey: {},
        hostIndex: {},
        localKey: "local"
    };
};

/* Display name for the header line: strip trailing .local.mesh (assumed). */
export function shortMeshName(name)
{
    if (!name) {
        return name;
    }
    return replace(name, /\.local\.mesh$/, "");
};

/* Keep in sync with build.sh -v/-r (and bump-traceroute-revision rule). */
export function packageVersion()
{
    return "0.1.32-r0";
};

/**
 * Visual-traceroute / meshinfo shared schema (schemaVersion 1).
 * traceroute emits one path; stableroute emits many.
 */
export function hopIdentity(hop)
{
    if (!hop || hop.unreachable) {
        return "*";
    }
    const host = shortMeshName(hop.hostname);
    if (host && host !== hop.ip) {
        return lc(host);
    }
    if (hop.ip) {
        return hop.ip;
    }
    return "*";
};

export function pathKeyFromHops(hops)
{
    const parts = [];
    for (let i = 0; i < length(hops); i++) {
        push(parts, hopIdentity(hops[i]));
    }
    return join("|", parts);
};

function rttMsNumber(rtt)
{
    if (rtt == null || rtt === "") {
        return null;
    }
    const n = rtt * 1;
    if (n != n) {
        return null;
    }
    return int(n + (n < 0 ? -0.5 : 0.5));
};

export function buildTracerouteJson(dest, hops, options)
{
    const destShort = shortMeshName(dest);
    const reached = !!(options && options.reached);
    const using = (options && options.using) || "aredn-traceroute";
    const babelMetric = (options && options.babelMetric != null) ? options.babelMetric : null;
    const outHops = [];
    for (let i = 0; i < length(hops); i++) {
        const h = hops[i] || {};
        const rec = {
            hop: h.hop,
            hostname: h.unreachable ? null : shortMeshName(h.hostname),
            ip: h.unreachable ? null : (h.ip || null),
            linkType: h.linkType || null,
            rttMs: h.unreachable ? null : rttMsNumber(h.rtt),
            rttAvgMs: null,
            rttDevMs: null,
            lat: h.lat != null && h.lat !== "" ? (h.lat * 1) : null,
            lon: h.lon != null && h.lon !== "" ? (h.lon * 1) : null,
            unreachable: !!h.unreachable
        };
        if (h.metric != null) {
            rec.metric = h.metric;
        }
        push(outHops, rec);
    }
    return {
        schemaVersion: 1,
        tool: "aredn-traceroute",
        version: packageVersion(),
        destination: destShort,
        source: null,
        using: using,
        runs: 1,
        babelMetric: babelMetric,
        summary: {
            uniquePaths: 1,
            shortest: length(outHops),
            longest: length(outHops),
            unreachable: reached ? 0 : 1,
            mostCommonCount: 1
        },
        paths: [
            {
                index: 1,
                key: pathKeyFromHops(hops),
                count: 1,
                reached: reached,
                hops: outHops
            }
        ]
    };
};

export function formatBanner(node, dest, destMetric)
{
    const metricPart = destMetric != null ? `${destMetric}` : "-";
    return `Aredn-Traceroute(${packageVersion()}): Babel Metric ${metricPart}`;
};

function resolveDestIp(dest)
{
    if (!dest) {
        return null;
    }
    if (match(dest, /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/)) {
        return dest;
    }
    const short = lc(replace(dest, /\.local\.mesh$/, ""));
    try {
        const nodes = mesh.getNodeList();
        for (let i = 0; i < length(nodes); i++) {
            const n = nodes[i];
            if (n && n.ip && n.name && lc(n.name) === short) {
                return n.ip;
            }
        }
    }
    catch (_) {
    }
    try {
        const p = fs.popen(`/usr/bin/resolveip -4 -t 1 ${dest} 2>/dev/null`);
        if (p) {
            const ip = trim(p.read("line") || "");
            p.close();
            if (match(ip, /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/)) {
                return ip;
            }
        }
    }
    catch (_) {
    }
    return null;
}

/**
 * Babel path metric from this node to dest (hostname or IP).
 * Same host-route metric used as the last field on each hop line.
 */
export function lookupDestPathMetric(dest)
{
    if (!dest) {
        return null;
    }
    if (!match(dest, /\./) && !match(dest, /^[0-9.]+$/)) {
        dest = `${dest}.local.mesh`;
    }
    const ctx = createContext();
    seedLocalRouteMetrics(ctx);
    const ip = resolveDestIp(dest);
    if (!ip) {
        return null;
    }
    return localPathMetric(ctx, ip);
};

function storeEntry(ctx, key, entry)
{
    ctx.byKey[key] = entry;
    if (entry.hostname) {
        ctx.hostIndex[lc(entry.hostname)] = key;
        const short = match(entry.hostname, /^([^.]+)/);
        if (short) {
            ctx.hostIndex[lc(short[1])] = key;
        }
    }
    if (entry.ip) {
        ctx.hostIndex[entry.ip] = key;
    }
    return entry;
}

function cacheKey(hostOrIp)
{
    if (!hostOrIp) {
        return null;
    }
    if (match(hostOrIp, /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/)) {
        return hostOrIp;
    }
    return lc(replace(hostOrIp, /\.local\.mesh$/, ""));
}

export function seedLocal(ctx)
{
    let trackers = {};
    let lat = null;
    let lon = null;
    let hostname = null;
    try {
        hostname = configuration.getName();
    }
    catch (_) {
    }
    if (ctx.wantGps) {
        try {
            const c = uci.cursor();
            lat = toNum(c.get("aredn", "@location[0]", "lat"));
            lon = toNum(c.get("aredn", "@location[0]", "lon"));
        }
        catch (_) {
        }
    }
    try {
        if (fs.access("/tmp/lqm.info")) {
            const lqm = json(fs.readfile("/tmp/lqm.info"));
            trackers = lqm.trackers || {};
        }
    }
    catch (_) {
    }
    const idx = indexTrackers(trackers);
    let gpsReason = null;
    if (ctx.wantGps && (lat == null || lon == null)) {
        gpsReason = "local node has no lat/lon in aredn.@location[0]";
    }
    let firmwareVersion = null;
    try {
        firmwareVersion = configuration.getFirmwareVersion();
    }
    catch (_) {
    }
    return storeEntry(ctx, ctx.localKey, {
        key: ctx.localKey,
        local: true,
        failed: false,
        fetchHost: null,
        failReason: null,
        gpsReason: gpsReason,
        displayName: hostname,
        lat: lat,
        lon: lon,
        hostname: hostname,
        ip: null,
        firmwareVersion: firmwareVersion,
        trackers: trackers,
        byIp: idx.byIp,
        byHost: idx.byHost
    });
};

/* Mesh identity: br-mesh on RF nodes, br-nomesh on tunnel servers that have no mesh bridge. */
function meshIpFromSysinfo(info, hostOrIp)
{
    if (info && info.ip && match(info.ip, /^10\./)) {
        return info.ip;
    }
    const ifaces = (info && info.interfaces) ? info.interfaces : [];
    let nomesh = null;
    for (let i = 0; i < length(ifaces); i++) {
        const iface = ifaces[i];
        if (!iface || !iface.ip || !match(iface.ip, /^10\./)) {
            continue;
        }
        if (iface.name === "br-mesh") {
            return iface.ip;
        }
        if (iface.name === "br-nomesh") {
            nomesh = iface.ip;
        }
    }
    if (nomesh) {
        return nomesh;
    }
    if (info && info.ip && !match(info.ip, /^172\.(29|30|31)\./)) {
        return info.ip;
    }
    if (hostOrIp && match(hostOrIp, /^10\.[0-9]+\.[0-9]+\.[0-9]+$/)) {
        return hostOrIp;
    }
    return null;
}

function fetchJson(url)
{
    const p = fs.popen(`${UFETCH} -T ${FETCH_TIMEOUT} "${url}" -O - 2> /dev/null`);
    if (!p) {
        return null;
    }
    let body = "";
    for (let chunk = p.read("line"); length(chunk); chunk = p.read("line")) {
        body += chunk;
    }
    p.close();
    if (!body) {
        return null;
    }
    try {
        return json(body);
    }
    catch (_) {
        return null;
    }
}

export function ensureNode(ctx, hostOrIp)
{
    const key = cacheKey(hostOrIp);
    if (!key) {
        return null;
    }
    if (ctx.byKey[key]) {
        return ctx.byKey[key];
    }
    if (ctx.hostIndex[key] && ctx.byKey[ctx.hostIndex[key]]) {
        return ctx.byKey[ctx.hostIndex[key]];
    }

    const host = meshHost(hostOrIp);
    const url = `http://${host}/a/sysinfo?lqm=1`;
    const info = fetchJson(url);
    if (!info) {
        return storeEntry(ctx, key, {
            key: key,
            local: false,
            failed: true,
            fetchHost: host,
            failReason: `sysinfo fetch failed (${url}); timeout, unreachable, or non-AREDN hop`,
            gpsReason: ctx.wantGps ? `no GPS: sysinfo fetch failed for ${host}` : null,
            lat: null,
            lon: null,
            hostname: hostOrIp,
            ip: match(hostOrIp, /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) ? hostOrIp : null,
            firmwareVersion: null,
            interfaces: [],
            trackers: {},
            byIp: {},
            byHost: {}
        });
    }

    const trackers = (info.lqm && info.lqm.info && info.lqm.info.trackers) ? info.lqm.info.trackers : {};
    const idx = indexTrackers(trackers);
    const ip = meshIpFromSysinfo(info, hostOrIp);
    const hostname = info.node || info.hostname || hostOrIp;
    const firmwareVersion = (info.node_details && info.node_details.firmware_version)
        ? info.node_details.firmware_version
        : null;
    let lat = null;
    let lon = null;
    let gpsReason = null;
    if (ctx.wantGps) {
        lat = info.lat;
        lon = info.lon;
        if (lat == null || lon == null || lat === "" || lon === "") {
            gpsReason = `node ${hostname} responded to sysinfo but lat/lon are unset (aredn.@location[0])`;
        }
    }
    const entry = storeEntry(ctx, key, {
        key: key,
        local: false,
        failed: false,
        fetchHost: host,
        failReason: null,
        gpsReason: gpsReason,
        lat: lat,
        lon: lon,
        hostname: hostname,
        ip: ip,
        firmwareVersion: firmwareVersion,
        interfaces: info.interfaces || [],
        trackers: trackers,
        byIp: idx.byIp,
        byHost: idx.byHost
    });
    if (ip && ip !== key) {
        ctx.byKey[ip] = entry;
        ctx.hostIndex[ip] = key;
    }
    return entry;
};

function isIpv4(s)
{
    return s && match(s, /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) ? true : false;
}

function hasNeighborIndex(entry)
{
    if (!entry || !entry.byIp) {
        return false;
    }
    for (let k in entry.byIp) {
        return true;
    }
    return false;
}

function rebindEntry(ctx, failedOrOld, good)
{
    if (!failedOrOld || !good) {
        return;
    }
    if (failedOrOld.ip) {
        ctx.byKey[failedOrOld.ip] = good;
        ctx.hostIndex[failedOrOld.ip] = good.key;
    }
    if (failedOrOld.key && failedOrOld.key !== good.key) {
        ctx.byKey[failedOrOld.key] = good;
    }
    if (failedOrOld.displayName && !match(failedOrOld.displayName, /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/)) {
        good.displayName = good.displayName || failedOrOld.displayName;
        const dk = cacheKey(failedOrOld.displayName);
        if (dk) {
            ctx.hostIndex[dk] = good.key;
        }
    }
}

/**
 * Prefer LQM from a previous hop entry. If that entry was only reachable via a
 * traceroute IP (often a tunnel address) but we later learned a mesh hostname
 * for it, re-fetch sysinfo via that hostname and use its LQM for lookups.
 */
function getLqmSource(ctx, prevKey)
{
    let prev = ctx.byKey[prevKey] || (prevKey === ctx.localKey ? ctx.byKey[ctx.localKey] : null);
    if (!prev) {
        return null;
    }
    const altName = prev.displayName;
    const haveMeshName = altName && !isIpv4(altName) && altName !== prev.ip;
    // Tunnel/traceroute IPs can return sysinfo with a neighbor table that does not
    // index the next hop the way mesh-hostname sysinfo does. Prefer hostname refresh.
    const fetchedViaIp = prev.fetchHost && isIpv4(prev.fetchHost);
    const shouldRefresh = haveMeshName && (prev.failed || !hasNeighborIndex(prev) || fetchedViaIp);
    if (!shouldRefresh) {
        return prev;
    }
    const altKey = cacheKey(altName);
    if (altKey && ctx.byKey[altKey] && !ctx.byKey[altKey].failed) {
        const alt = ctx.byKey[altKey];
        alt.refreshedViaHostname = true;
        alt.displayName = alt.displayName || altName;
        rebindEntry(ctx, prev, alt);
        return alt;
    }
    const alt = ensureNode(ctx, altName);
    if (alt && !alt.failed) {
        alt.refreshedViaHostname = true;
        alt.displayName = alt.displayName || altName;
        rebindEntry(ctx, prev, alt);
        return alt;
    }
    return prev;
}

export function lookupLink(ctx, prevKey, nextIp, nextHost)
{
    const prev = getLqmSource(ctx, prevKey);
    const prevLabel = prev ? (prev.displayName || prev.hostname || prev.ip || prevKey) : prevKey;
    if (!prev) {
        const why = `no LQM data for previous hop (${prevKey})`;
        return {
            type: null,
            txcost: null,
            rxcost: null,
            txSuccess: null,
            rxSuccess: null,
            neighborErrors: null,
            typeReason: why,
            costReason: why,
            qualityReason: why,
            errorsReason: why,
            viaHostname: false
        };
    }
    if (prev.failed) {
        const why = prev.failReason || `previous hop ${prevLabel} sysinfo/LQM unavailable`;
        return {
            type: null,
            txcost: null,
            rxcost: null,
            txSuccess: null,
            rxSuccess: null,
            neighborErrors: null,
            typeReason: `link type unknown: ${why}`,
            costReason: `link cost unknown: ${why}`,
            qualityReason: `tx/rx success unknown: ${why}`,
            errorsReason: `neighbor errors unknown: ${why}`,
            viaHostname: false
        };
    }
    const tracker = findNeighbor(prev, nextIp, nextHost);
    if (!tracker) {
        const target = nextIp || nextHost || "?";
        const why = `${target} not found as a Babel/LQM neighbor of previous hop ${prevLabel}`;
        return {
            type: null,
            txcost: null,
            rxcost: null,
            txSuccess: null,
            rxSuccess: null,
            neighborErrors: null,
            typeReason: `link type unknown: ${why}`,
            costReason: `link cost unknown: ${why}`,
            qualityReason: `tx/rx success unknown: ${why}`,
            errorsReason: `neighbor errors unknown: ${why}`,
            viaHostname: prev.refreshedViaHostname ? true : false
        };
    }
    const type = mapLinkType(tracker.type);
    const stats = linkStats(tracker);
    const haveCost = stats.txcost != null || stats.rxcost != null;
    const haveQuality = stats.txSuccess != null || stats.rxSuccess != null;
    return {
        type: type,
        txcost: stats.txcost,
        rxcost: stats.rxcost,
        txSuccess: stats.txSuccess,
        rxSuccess: stats.rxSuccess,
        neighborErrors: stats.neighborErrors,
        typeReason: type ? null : `neighbor ${nextIp || nextHost} on ${prevLabel} has no link type`,
        costReason: haveCost ? null : `neighbor on ${prevLabel} has no LQM txcost/rxcost`,
        qualityReason: haveQuality ? null : `neighbor on ${prevLabel} has no LQM lq/rev_lq (rx/tx success)`,
        errorsReason: stats.neighborErrors != null ? null : `neighbor on ${prevLabel} has no LQM rev_quality (neighbor errors)`,
        viaHostname: prev.refreshedViaHostname ? true : false,
        prevLabel: prevLabel,
        neighborHostname: tracker.hostname || null
    };
};

export function formatGps(lat, lon)
{
    if (lat == null || lon == null || lat === "" || lon === "") {
        return "-";
    }
    return `${lat},${lon}`;
};

function fmtDash(v)
{
    return v != null && v !== "" ? `${v}` : "-";
}

function fmtPct(v)
{
    return v != null && v !== "" ? `${v}%` : "-";
}

export function formatHopLine(hopNum, hostname, ip, rtt, lat, lon, type, txcost, rxcost, txSuccess, rxSuccess, metric, neighborErrors, firmwareVersion, includeGps, txRxInfo, nodeVersion)
{
    const host = shortMeshName(hostname || ip || "?");
    const ipPart = ip ? ` (${ip})` : "";
    let rttPart = "";
    if (rtt != null && rtt !== "") {
        const rttN = +rtt;
        rttPart = rttN == rttN ? ` ${int(rttN + 0.5)} ms` : ` ${rtt} ms`;
    }
    const t = type || "-";
    const m = fmtDash(metric);
    let line = ` ${hopNum} ${host}${ipPart}${rttPart}`;
    if (includeGps) {
        line += ` ${formatGps(lat, lon)}`;
    }
    line += ` ${t}`;
    if (txRxInfo) {
        line += ` ${fmtDash(txcost)}/${fmtDash(rxcost)} (${fmtPct(txSuccess)}/${fmtPct(rxSuccess)})`;
    }
    line += ` ${m}`;
    if (txRxInfo) {
        line += ` ${fmtPct(neighborErrors)}`;
    }
    if (nodeVersion) {
        line += ` ${fmtDash(firmwareVersion)}`;
    }
    return line;
};

/**
 * Prefer a real nodename when traceroute only showed an IP.
 * Sources: this hop's sysinfo (node), else previous hop's LQM neighbor hostname
 * (refreshing previous hop via its resolved mesh hostname if the traceroute IP failed).
 * Returns { name, source, from }.
 */
function resolveDisplayHostname(ctx, prevKey, hop, node)
{
    let name = hop.hostname;
    if (name && !isIpv4(name) && name !== hop.ip) {
        if (!match(name, /\./)) {
            name = `${name}.local.mesh`;
        }
        return { name: name, source: "traceroute" };
    }

    if (node && node.hostname && !isIpv4(node.hostname) && node.hostname !== hop.ip) {
        name = node.hostname;
        if (!match(name, /\./)) {
            name = `${name}.local.mesh`;
        }
        return { name: name, source: "sysinfo" };
    }

    const prev = getLqmSource(ctx, prevKey);
    if (prev && !prev.failed) {
        const tracker = findNeighbor(prev, hop.ip, hop.hostname);
        if (tracker && tracker.hostname && !isIpv4(tracker.hostname)) {
            name = tracker.hostname;
            if (!match(name, /\./)) {
                name = `${name}.local.mesh`;
            }
            const prevLabel = prev.displayName || prev.hostname || prev.ip || prevKey;
            const source = prev.refreshedViaHostname ? "previous_lqm_via_hostname" : "previous_lqm";
            return { name: name, source: source, from: prevLabel };
        }
    }

    return { name: hop.hostname || hop.ip, source: "unresolved" };
}

/**
 * Parse a busybox traceroute hop line.
 * Returns null if not a hop line.
 */
export function parseHopLine(line)
{
    line = trim(line);
    if (!line) {
        return null;
    }
    let m = match(line, /^([0-9]+) +\* +\* +\*/);
    if (m) {
        return { hop: int(m[1]), unreachable: true };
    }
    m = match(line, /^([0-9]+) +([^ ]+) \(([0-9.]+)\) +([0-9.]+) +ms/);
    if (m) {
        return {
            hop: int(m[1]),
            hostname: m[2],
            ip: m[3],
            rtt: m[4],
            unreachable: false
        };
    }
    m = match(line, /^([0-9]+) +([0-9.]+) +([0-9.]+) +ms/);
    if (m) {
        return {
            hop: int(m[1]),
            hostname: m[2],
            ip: m[2],
            rtt: m[3],
            unreachable: false
        };
    }
    return null;
};

export function enrichHop(ctx, prevKey, hop)
{
    if (hop.unreachable) {
        return {
            line: ` ${hop.hop}  * * *`,
            notes: [ "    # unreachable hop (* * *); no GPS/link metadata" ],
            nextKey: prevKey,
            record: {
                hop: hop.hop,
                hostname: null,
                ip: null,
                rtt: null,
                linkType: null,
                lat: null,
                lon: null,
                metric: null,
                unreachable: true
            }
        };
    }
    let node = ensureNode(ctx, hop.ip || hop.hostname);
    // Resolve name first so a failed tunnel-IP prev can be refreshed via its mesh hostname.
    let resolved = resolveDisplayHostname(ctx, prevKey, hop, node);
    // Snapshot previous-hop name provenance for -verbose before any sysinfo rebind.
    let nameFromPrev = null;
    if (resolved.source === "previous_lqm" || resolved.source === "previous_lqm_via_hostname") {
        nameFromPrev = {
            name: resolved.name,
            source: resolved.source,
            from: resolved.from
        };
    }
    // If we learned a mesh hostname (especially from previous-hop LQM), prefer
    // sysinfo via that name when the traceroute IP failed, has no neighbors, or
    // was only fetched by numeric IP (tunnel addresses often need this).
    if (resolved.name && !isIpv4(resolved.name) && resolved.name !== hop.ip) {
        const fetchedViaIp = node && node.fetchHost && isIpv4(node.fetchHost);
        const needNameFetch = !node || node.failed || !hasNeighborIndex(node) || fetchedViaIp;
        if (needNameFetch) {
            const byName = ensureNode(ctx, resolved.name);
            if (byName && !byName.failed) {
                if (node) {
                    rebindEntry(ctx, node, byName);
                }
                node = byName;
                if (byName.hostname && !isIpv4(byName.hostname) && !hop.tunnelIp) {
                    resolved = { name: meshHost(byName.hostname) || byName.hostname, source: "sysinfo" };
                }
            }
        }
    }
    const link = lookupLink(ctx, prevKey, hop.ip, hop.hostname);
    const pathMetric = resolvePathMetric(ctx, hop, node);
    // If name still unresolved, try again after prev may have been refreshed via hostname.
    if (resolved.source === "unresolved") {
        resolved = resolveDisplayHostname(ctx, prevKey, hop, node);
        if (resolved.source === "previous_lqm" || resolved.source === "previous_lqm_via_hostname") {
            nameFromPrev = {
                name: resolved.name,
                source: resolved.source,
                from: resolved.from
            };
        }
    }
    const hostname = resolved.name;
    if (node) {
        node.displayName = hostname;
        if (!isIpv4(hostname) && hostname !== hop.ip) {
            const hk = cacheKey(hostname);
            if (hk) {
                ctx.hostIndex[hk] = node.key;
            }
        }
        if (hop.tunnelIp && !node.failed) {
            const old = ctx.byKey[hop.tunnelIp];
            if (old && old !== node) {
                rebindEntry(ctx, old, node);
            }
            else if (!old) {
                ctx.byKey[hop.tunnelIp] = node;
            }
        }
    }
    const wantGps = ctx.wantGps ? true : false;
    const txRxInfo = ctx.txRxInfo !== false;
    const nodeVersion = ctx.nodeVersion ? true : false;
    const lat = wantGps && node ? node.lat : null;
    const lon = wantGps && node ? node.lon : null;
    const firmwareVersion = node ? node.firmwareVersion : null;
    let nextKey = (node && node.key) ? node.key : (cacheKey(hop.ip || hop.hostname) || prevKey);
    // Prefer mesh-IP/hostname cache key when we rebound a failed tunnel entry.
    if (node && !node.failed && node.ip && hop.ip && node.ip !== hop.ip) {
        nextKey = node.key;
    }
    const notes = [];
    if (hop.tunnelIp) {
        const shown = (hop.ip && match(hop.ip, /^10\./)) ? hop.ip : ((node && node.ip) ? node.ip : hop.ip);
        push(notes, `    # name: ${shortMeshName(hostname)} (${shown}) owns tunnel address ${hop.tunnelIp} (${hop.tunnelVia || "tunnel interface"})`);
    }
    else if (nameFromPrev) {
        if (nameFromPrev.source === "previous_lqm_via_hostname") {
            push(notes, `    # name: ${hostname} from previous hop ${nameFromPrev.from} LQM (refetched via mesh hostname after traceroute IP failed)`);
        }
        else {
            push(notes, `    # name: ${hostname} from previous hop ${nameFromPrev.from} LQM neighbor list`);
        }
    }
    else if (resolved.source === "unresolved") {
        push(notes, `    # name: no hostname from sysinfo or previous hop LQM for ${hop.ip || hop.hostname}`);
    }
    if (link.viaHostname) {
        push(notes, `    # link: previous hop LQM loaded via resolved hostname ${link.prevLabel}`);
    }
    if (pathMetric.source === "local_route_mesh_ip" && node && node.ip) {
        push(notes, `    # metric: Babel path metric via mesh IP ${node.ip} (traceroute hop IP not in local host routes)`);
    }
    if (wantGps && (lat == null || lon == null || lat === "" || lon === "")) {
        if (node && node.gpsReason) {
            push(notes, `    # GPS -: ${node.gpsReason}`);
        }
        else if (!node) {
            push(notes, "    # GPS -: could not resolve hop for sysinfo lookup");
        }
        else {
            push(notes, "    # GPS -: lat/lon unavailable");
        }
    }
    if (!link.type && link.typeReason) {
        push(notes, `    # type -: ${link.typeReason}`);
    }
    if (txRxInfo && (link.txcost == null && link.rxcost == null) && link.costReason) {
        push(notes, `    # cost -: ${link.costReason}`);
    }
    if (txRxInfo && (link.txSuccess == null && link.rxSuccess == null) && link.qualityReason) {
        push(notes, `    # success -: ${link.qualityReason}`);
    }
    if (pathMetric.metric == null && pathMetric.reason) {
        push(notes, `    # metric -: ${pathMetric.reason}`);
    }
    if (txRxInfo && link.neighborErrors == null && link.errorsReason) {
        push(notes, `    # errors -: ${link.errorsReason}`);
    }
    if (nodeVersion && (firmwareVersion == null || firmwareVersion === "")) {
        push(notes, `    # version -: no firmware_version from sysinfo for ${hop.ip || hop.hostname}`);
    }
    return {
        line: formatHopLine(hop.hop, hostname, hop.ip, hop.rtt, lat, lon, link.type, link.txcost, link.rxcost, link.txSuccess, link.rxSuccess, pathMetric.metric, link.neighborErrors, firmwareVersion, wantGps, txRxInfo, nodeVersion),
        notes: notes,
        nextKey: nextKey,
        record: {
            hop: hop.hop,
            hostname: hostname,
            ip: hop.ip,
            rtt: hop.rtt,
            linkType: link.type || null,
            lat: lat,
            lon: lon,
            metric: pathMetric.metric,
            unreachable: false
        }
    };
};

/*
 * 172.29/30/31 hops are WireGuard interface addresses of the router that sent
 * ICMP time-exceeded. They are not mesh routes, and current LQM sysinfo often
 * lists that neighbor only by hostname + canonical 10. address (no tunnel ip).
 * The address itself is on the router's sysinfo interface list.
 */
function isTunnelHopIp(ip)
{
    return ip && match(ip, /^172\.(29|30|31)\.[0-9]+\.[0-9]+$/) ? true : false;
}

function canonHost(name)
{
    if (!name || name === "*") {
        return null;
    }
    let h = lc(trim(name));
    h = replace(h, /\.local\.mesh$/, "");
    h = replace(h, /^dtdlink\./, "");
    h = replace(h, /^supernode\./, "");
    h = replace(h, /^lan\./, "");
    h = replace(h, /^xlink[0-9]+\./, "");
    h = replace(h, /^mid[0-9]+\./, "");
    if (!h || isIpv4(h)) {
        return null;
    }
    return h;
}

function interfaceHasIp(entry, ip)
{
    if (!entry || !ip || !entry.interfaces) {
        return false;
    }
    for (let i = 0; i < length(entry.interfaces); i++) {
        const iface = entry.interfaces[i];
        if (!iface || !iface.ip) {
            continue;
        }
        let addr = iface.ip;
        const slash = match(addr, /^([^/]+)/);
        if (slash) {
            addr = slash[1];
        }
        if (addr === ip) {
            return true;
        }
    }
    return false;
}

function meshIpOf(node, hint)
{
    if (node && node.ip && match(node.ip, /^10\./)) {
        return node.ip;
    }
    if (hint && match(hint, /^10\./)) {
        return hint;
    }
    if (node && node.interfaces) {
        let nomesh = null;
        for (let i = 0; i < length(node.interfaces); i++) {
            const iface = node.interfaces[i];
            if (!iface || !iface.ip || !match(iface.ip, /^10\./)) {
                continue;
            }
            if (iface.name === "br-mesh") {
                return iface.ip;
            }
            if (iface.name === "br-nomesh") {
                nomesh = iface.ip;
            }
        }
        if (nomesh) {
            return nomesh;
        }
    }
    return null;
}

function trackerNeighbors(entry)
{
    const out = [];
    const seen = {};
    if (!entry || entry.failed || !entry.trackers) {
        return out;
    }
    for (let mac in entry.trackers) {
        const t = entry.trackers[mac];
        if (!t) {
            continue;
        }
        const host = canonHost(t.hostname);
        if (!host || seen[host]) {
            continue;
        }
        seen[host] = true;
        let meshIp = null;
        if (t.canonical_ip && match(t.canonical_ip, /^10\./)) {
            meshIp = t.canonical_ip;
        }
        push(out, {
            host: host,
            meshIp: meshIp,
            type: t.type || ""
        });
    }
    return out;
}

function tunnelHopUnresolved(hop)
{
    return hop && !hop.unreachable && !hop.tunnelIp && isTunnelHopIp(hop.ip);
}

function anchorAt(ctx, item)
{
    if (!item || item.kind !== "hop" || !item.hop || item.hop.unreachable || !item.enriched) {
        return null;
    }
    const rec = item.enriched.record;
    if (!rec || rec.unreachable) {
        return null;
    }
    // Still-raw tunnel hops cannot anchor; ones already rewritten to name + 10. can.
    if (tunnelHopUnresolved(item.hop)) {
        return null;
    }
    if (isIpv4(rec.hostname) && !item.hop.tunnelIp) {
        return null;
    }
    const node = ctx.byKey[item.enriched.nextKey];
    if (!node || node.failed) {
        return null;
    }
    const label = shortMeshName(node.displayName || node.hostname || rec.hostname || node.ip || "?");
    return { node: node, label: label };
}

function reenrichFrom(ctx, events, fromIdx)
{
    if (fromIdx == null || fromIdx < 0) {
        return;
    }
    let prevKey = ctx.localKey;
    for (let i = 0; i < length(events); i++) {
        const item = events[i];
        if (!item || item.kind !== "hop") {
            continue;
        }
        if (item.hop.unreachable) {
            continue;
        }
        if (i >= fromIdx) {
            item.enriched = enrichHop(ctx, prevKey, item.hop);
        }
        prevKey = item.enriched.nextKey;
    }
}

function nearestAnchor(ctx, events, idx, step)
{
    for (let i = idx + step; i >= 0 && i < length(events); i += step) {
        const a = anchorAt(ctx, events[i]);
        if (a) {
            return a;
        }
    }
    return null;
}

function queueNeighbors(list, seen, neighbors, via, skip)
{
    const wg = [];
    const other = [];
    for (let i = 0; i < length(neighbors); i++) {
        const n = neighbors[i];
        if (!n || !n.host || seen[n.host] || (skip && skip[n.host])) {
            continue;
        }
        if (n.type === "Wireguard" || n.type === "Xlink") {
            push(wg, n);
        }
        else {
            push(other, n);
        }
    }
    for (let i = 0; i < length(wg); i++) {
        seen[wg[i].host] = true;
        push(list, { host: wg[i].host, meshIp: wg[i].meshIp, via: via });
    }
    for (let i = 0; i < length(other); i++) {
        seen[other[i].host] = true;
        push(list, { host: other[i].host, meshIp: other[i].meshIp, via: via });
    }
}

function ownerFromNode(node, hintIp, via)
{
    if (!node || node.failed) {
        return null;
    }
    const meshIp = meshIpOf(node, hintIp);
    const name = canonHost(node.hostname) || canonHost(node.displayName);
    if (!name || !meshIp) {
        return null;
    }
    return { name: name, meshIp: meshIp, via: via };
}

/*
 * Find the node that owns a traceroute tunnel address.
 * Prefer a neighbor listed by both the previous and next non-tunnel hops,
 * then the other neighbors of those hops. Accept a candidate only when its
 * sysinfo interface list contains the tunnel address.
 */
function findTunnelOwner(ctx, events, idx)
{
    const hop = events[idx].hop;
    const tunnelIp = hop.ip;
    const named = canonHost(hop.hostname);
    if (named) {
        const namedNode = ensureNode(ctx, named);
        if (namedNode && !namedNode.failed && interfaceHasIp(namedNode, tunnelIp)) {
            const ident = ownerFromNode(namedNode, null, "sysinfo for traceroute name");
            if (ident) {
                return ident;
            }
        }
    }

    let prev = nearestAnchor(ctx, events, idx, -1);
    if (!prev && ctx.byKey[ctx.localKey] && !ctx.byKey[ctx.localKey].failed) {
        const local = ctx.byKey[ctx.localKey];
        prev = {
            node: local,
            label: shortMeshName(local.displayName || local.hostname || "this node")
        };
    }
    const next = nearestAnchor(ctx, events, idx, 1);
    const prevNode = prev ? prev.node : null;
    const nextNode = next ? next.node : null;
    const prevLabel = prev ? prev.label : null;
    const nextLabel = next ? next.label : null;

    if (prevNode && interfaceHasIp(prevNode, tunnelIp)) {
        const ident = ownerFromNode(prevNode, null, `interface on ${prevLabel}`);
        if (ident) {
            return ident;
        }
    }
    if (nextNode && interfaceHasIp(nextNode, tunnelIp)) {
        const ident = ownerFromNode(nextNode, null, `interface on ${nextLabel}`);
        if (ident) {
            return ident;
        }
    }

    const prevN = trackerNeighbors(prevNode);
    const nextN = trackerNeighbors(nextNode);
    const skip = {};
    if (prevLabel) {
        const ph = canonHost(prevLabel);
        if (ph) {
            skip[ph] = true;
        }
    }
    if (nextLabel) {
        const nh = canonHost(nextLabel);
        if (nh) {
            skip[nh] = true;
        }
    }
    const candidates = [];
    const seen = {};
    if (prevLabel && nextLabel) {
        const nextByHost = {};
        for (let i = 0; i < length(nextN); i++) {
            nextByHost[nextN[i].host] = nextN[i];
        }
        const bothVia = `common neighbor of ${prevLabel} and ${nextLabel}`;
        for (let i = 0; i < length(prevN); i++) {
            const n = prevN[i];
            if (!nextByHost[n.host] || seen[n.host] || skip[n.host]) {
                continue;
            }
            seen[n.host] = true;
            push(candidates, { host: n.host, meshIp: n.meshIp || nextByHost[n.host].meshIp, via: bothVia });
        }
    }
    if (prevLabel) {
        queueNeighbors(candidates, seen, prevN, `neighbor of ${prevLabel}`, skip);
    }
    if (nextLabel) {
        queueNeighbors(candidates, seen, nextN, `neighbor of ${nextLabel}`, skip);
    }

    const maxFetches = 32;
    let fetched = 0;
    for (let i = 0; i < length(candidates) && fetched < maxFetches; i++) {
        const c = candidates[i];
        const key = c.meshIp || c.host;
        const cached = ctx.byKey[cacheKey(key)];
        if (!cached) {
            fetched++;
        }
        const node = ensureNode(ctx, key);
        if (!node || node.failed || !interfaceHasIp(node, tunnelIp)) {
            continue;
        }
        const ident = ownerFromNode(node, c.meshIp, c.via);
        if (ident) {
            return ident;
        }
    }
    return null;
}

function applyTunnelIdentity(ctx, item, ident)
{
    item.hop.tunnelIp = item.hop.ip;
    item.hop.tunnelVia = ident.via;
    item.hop.hostname = ident.name;
    if (ident.meshIp) {
        item.hop.ip = ident.meshIp;
    }
    // Prefetch owner sysinfo so the following re-enrich (and later passes) can
    // use this hop as an LQM anchor for neighboring unresolved tunnel hops.
    const owner = ensureNode(ctx, ident.meshIp || ident.name);
    if (owner && !owner.failed) {
        const old = ctx.byKey[item.hop.tunnelIp];
        if (old && old !== owner) {
            rebindEntry(ctx, old, owner);
        }
        else if (!old) {
            ctx.byKey[item.hop.tunnelIp] = owner;
        }
        owner.displayName = owner.displayName || ident.name;
    }
}

/*
 * Resolve 172.29/30/31 hops, then repeat. Newly named hops become anchors so a
 * middle tunnel hop can resolve once its neighbors on either side are known.
 */
function resolveTunnelHops(ctx, events)
{
    let earliest = -1;
    const maxPasses = length(events) + 2;
    for (let pass = 0; pass < maxPasses; pass++) {
        let resolvedThisPass = 0;
        let passEarliest = -1;
        for (let i = 0; i < length(events); i++) {
            const item = events[i];
            if (!item || item.kind !== "hop" || !tunnelHopUnresolved(item.hop)) {
                continue;
            }
            const ident = findTunnelOwner(ctx, events, i);
            if (!ident) {
                continue;
            }
            applyTunnelIdentity(ctx, item, ident);
            resolvedThisPass++;
            if (passEarliest < 0) {
                passEarliest = i;
            }
        }
        if (resolvedThisPass === 0) {
            break;
        }
        if (earliest < 0 || passEarliest < earliest) {
            earliest = passEarliest;
        }
        // Rebuild enrichment so newly named hops expose LQM for the next pass.
        reenrichFrom(ctx, events, earliest);
    }
    for (let i = 0; i < length(events); i++) {
        const item = events[i];
        if (!item || item.kind !== "hop" || !item.hop || !tunnelHopUnresolved(item.hop)) {
            continue;
        }
        if (item.enriched && item.enriched.notes) {
            push(item.enriched.notes, `    # name: tunnel address ${item.hop.ip} matched no interface on the previous or next mesh hop`);
        }
    }
}

/**
 * Run traceroute and emit lines via printFn(line).
 * options.verbose: when true, print why unset fields are missing.
 * options.gps: include per-hop GPS (off by default).
 * options.txRxInfo: include txcost/rxcost, success%, neighborErrors% (on by default).
 * options.nodeVersion: append firmware_version from hop sysinfo (off by default).
 * options.headerLine: printed immediately after the stock "traceroute to …" banner
 *   so Tools → Traceroute (which skips lines until that banner) still shows it.
 * options.collectHops: when true, also return { ok, hops, dest } for JSON export.
 * Returns true on success, or { ok, hops, dest } when collectHops is set.
 */
export function runEnrichedTraceroute(dest, printFn, options)
{
    if (!dest) {
        return options && options.collectHops ? { ok: false, hops: [], dest: dest } : false;
    }
    if (!match(dest, /\./) && !match(dest, /^[0-9.]+$/)) {
        dest = `${dest}.local.mesh`;
    }
    const verbose = options && options.verbose;
    const headerLine = options && options.headerLine;
    const collectHops = !!(options && options.collectHops);
    let headerPending = headerLine ? true : false;
    const ctx = createContext();
    ctx.wantGps = !!(options && options.gps);
    ctx.txRxInfo = !(options && options.txRxInfo === false);
    ctx.nodeVersion = !!(options && options.nodeVersion);
    seedLocalRouteMetrics(ctx);
    seedLocal(ctx);
    let prevKey = ctx.localKey;
    const hops = [];
    const events = [];

    const running = fs.popen(`/bin/traceroute -q 1 -w 1 ${dest} 2>&1`);
    if (!running) {
        return collectHops ? { ok: false, hops: hops, dest: dest } : false;
    }
    for (let line = running.read("line"); length(line); line = running.read("line")) {
        line = replace(line, /\r?\n$/, "");
        const hop = parseHopLine(line);
        if (hop) {
            const enriched = enrichHop(ctx, prevKey, hop);
            push(events, { kind: "hop", hop: hop, enriched: enriched });
            if (!hop.unreachable) {
                prevKey = enriched.nextKey;
            }
        }
        else {
            push(events, { kind: "line", text: line });
        }
    }
    running.close();
    resolveTunnelHops(ctx, events);
    for (let i = 0; i < length(events); i++) {
        const ev = events[i];
        if (ev.kind === "line") {
            if (printFn) {
                printFn(ev.text);
            }
            if (headerPending && match(ev.text, /^traceroute/)) {
                if (printFn) {
                    printFn(headerLine);
                }
                headerPending = false;
            }
            continue;
        }
        if (headerPending && printFn) {
            printFn(headerLine);
            headerPending = false;
        }
        if (printFn) {
            printFn(ev.enriched.line);
            if (verbose && ev.enriched.notes) {
                for (let n = 0; n < length(ev.enriched.notes); n++) {
                    printFn(ev.enriched.notes[n]);
                }
            }
        }
        if (collectHops && ev.enriched.record) {
            push(hops, ev.enriched.record);
        }
    }
    if (headerPending && printFn) {
        printFn(headerLine);
    }
    if (collectHops) {
        return { ok: true, hops: hops, dest: dest };
    }
    return true;
};

/**
 * Run traceroute and return schemaVersion-1 JSON document (no text print).
 */
export function runEnrichedTracerouteJson(dest, options)
{
    const destMetric = lookupDestPathMetric(dest);
    const result = runEnrichedTraceroute(dest, null, {
        verbose: false,
        gps: !!(options && options.gps),
        txRxInfo: !(options && options.txRxInfo === false),
        nodeVersion: !!(options && options.nodeVersion),
        collectHops: true
    });
    if (!result || !result.ok) {
        return {
            ok: false,
            doc: buildTracerouteJson(dest, [], {
                reached: false,
                babelMetric: destMetric
            })
        };
    }
    const reached = length(result.hops) > 0 && !result.hops[length(result.hops) - 1].unreachable;
    return {
        ok: true,
        doc: buildTracerouteJson(result.dest, result.hops, {
            reached: reached,
            babelMetric: destMetric
        })
    };
};
