//! dynamic_routes.zig — Dynamic Route Registry & Adaptive Query Router
//! Thread-safe registry for autonomously created response routes.
const std = @import("std");

pub const MAX_ROUTES: usize = 32768;
pub const MAX_KEYWORDS: usize = 8;
pub const MIN_MATCH_CONFIDENCE_BP: u16 = 5000;
pub const HIGH_CONFIDENCE_BP: u16 = 8000;
pub const DEFAULT_CORPUS_CONFIDENCE_BP: u16 = 6000;
pub const DEFAULT_KG_CONFIDENCE_BP: u16 = 5500;
pub const DEFAULT_OPENAI_CONFIDENCE_BP: u16 = 7500;
pub const CONFIDENCE_DECAY_PER_DAY_BP: u16 = 50;
pub const PRUNE_THRESHOLD_BP: u16 = 3000;
pub const BP_PER_UNIT: u16 = 10000;

pub const RouteCategory = enum(u8) {
    factual = 0,
    creative = 1,
    opinion = 2,
    reasoning = 3,
    naturalness = 4,
    chitchat = 5,
    open_ended = 6,
    framework_query = 7, // E=mc²-i-E=mc⁻² framework-specific queries
    pub fn label(self: RouteCategory) []const u8 {
        return switch (self) {
            .factual => "factual",
            .creative => "creative",
            .opinion => "opinion",
            .reasoning => "reasoning",
            .naturalness => "naturalness",
            .chitchat => "chitchat",
            .open_ended => "open_ended",
            .framework_query => "framework",
        };
    }
};

pub const RouteSource = enum(u8) {
    corpus_extracted = 0,
    kg_synthesized = 1,
    openai_reinforced = 2,
    self_evaluated = 3,
    manual = 4,
    pub fn label(self: RouteSource) []const u8 {
        return switch (self) {
            .corpus_extracted => "corpus",
            .kg_synthesized => "kg",
            .openai_reinforced => "openai",
            .self_evaluated => "self_eval",
            .manual => "manual",
        };
    }
};

pub const DynamicRoute = struct {
    keywords: [MAX_KEYWORDS][]const u8 = [_][]const u8{""} ** MAX_KEYWORDS,
    keyword_count: u8 = 0,
    response: []const u8 = "",
    confidence_bp: u16 = 0,
    category: RouteCategory = .factual,
    source: RouteSource = .manual,
    created_at: i64 = 0,
    last_used: i64 = 0,
    hit_count: u32 = 0,
    positive_eval_count: u32 = 0,
    negative_eval_count: u32 = 0,
    context_topic: [64]u8 = [_]u8{0} ** 64,
    context_len: u8 = 0,

    pub fn confidenceF64(self: DynamicRoute) f64 {
        return @as(f64, @floatFromInt(self.confidence_bp)) / @as(f64, @floatFromInt(BP_PER_UNIT));
    }

    pub fn decayedConfidence(self: DynamicRoute, now: i64) u16 {
        if (self.last_used == 0) return self.confidence_bp;
        const age_days = @divTrunc(now - self.last_used, 86400);
        if (age_days <= 0) return self.confidence_bp;
        const decay = @as(u32, @intCast(@min(age_days, std.math.maxInt(u32)))) * CONFIDENCE_DECAY_PER_DAY_BP;
        const dec = @as(u16, @intCast(@min(decay, std.math.maxInt(u16))));
        return if (dec >= self.confidence_bp) 0 else self.confidence_bp - dec;
    }

    pub fn updateConfidence(self: *DynamicRoute, positive: bool) void {
        if (positive) {
            self.positive_eval_count +%= 1;
            const bump: u16 = @intCast(@min(@as(u32, 200), @as(u32, 10000) - self.confidence_bp));
            self.confidence_bp += bump;
        } else {
            self.negative_eval_count +%= 1;
            const cut: u16 = @intCast(@min(@as(u32, 300), self.confidence_bp));
            self.confidence_bp -= cut;
        }
    }

    pub fn matches(self: DynamicRoute, prompt: []const u8) bool {
        if (self.keyword_count == 0) return false;
        // Reject single-keyword routes with common stopwords (e.g., "what", "which", "is", "the")
        // to prevent broad false matches on common words.
        if (self.keyword_count == 1 and isSingleKeywordStopword(self.keywords[0])) return false;
        // Reject single-keyword routes with very short keywords (e.g., "i", "a", "an")
        // to prevent false matches on common short words.
        if (self.keyword_count == 1 and self.keywords[0].len < 3) return false;
        var matched: u8 = 0;
        for (0..self.keyword_count) |i| {
            if (containsWordCI(prompt, self.keywords[i])) matched += 1;
        }
        return matched == self.keyword_count;
    }
};

fn topicEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    return std.ascii.eqlIgnoreCase(a, b);
}

const SINGLE_KEYWORD_STOPWORDS = [_][]const u8{
    "what", "which", "this",  "that",  "these", "those", "where", "when",
    "how",  "why",   "who",   "whom",  "whose", "is",    "are",   "was",
    "were", "been",  "being", "have",  "has",   "had",   "the",   "a",
    "an",   "and",   "or",    "but",   "not",   "for",   "with",  "from",
    "into", "onto",  "upon",  "about", "above", "below", "it",    "its",
    "his",  "her",   "their", "our",   "your",  "they",  "them",  "also",
    "such", "than",  "then",  "there", "here",  "very",  "much",  "many",
    "some", "any",   "all",   "each",  "both",  "more",  "most",  "only",
};

fn isSingleKeywordStopword(keyword: []const u8) bool {
    for (SINGLE_KEYWORD_STOPWORDS) |sw| {
        if (std.ascii.eqlIgnoreCase(keyword, sw)) return true;
    }
    return false;
}

fn containsWordCI(text: []const u8, word: []const u8) bool {
    if (word.len == 0) return false;
    if (text.len < word.len) return false;
    var i: usize = 0;
    while (i <= text.len - word.len) {
        if (std.ascii.startsWithIgnoreCase(text[i..], word)) {
            const left_ok = i == 0 or !std.ascii.isAlphabetic(text[i - 1]);
            const right_idx = i + word.len;
            const right_ok = right_idx >= text.len or !std.ascii.isAlphabetic(text[right_idx]);
            if (left_ok and right_ok) return true;
        }
        i += 1;
    }
    return false;
}

pub const DynamicRouteRegistry = struct {
    allocator: std.mem.Allocator,
    routes: std.ArrayList(DynamicRoute),
    mutex: std.Thread.Mutex = .{},

    pub fn init(allocator: std.mem.Allocator) DynamicRouteRegistry {
        return .{
            .allocator = allocator,
            .routes = std.ArrayList(DynamicRoute).init(allocator),
        };
    }

    pub fn deinit(self: *DynamicRouteRegistry) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.routes.items) |*route| {
            for (0..route.keyword_count) |i| {
                self.allocator.free(route.keywords[i]);
            }
            self.allocator.free(route.response);
        }
        self.routes.deinit();
    }

    pub fn register(
        self: *DynamicRouteRegistry,
        keywords: []const []const u8,
        response: []const u8,
        confidence_bp: u16,
        category: RouteCategory,
        source: RouteSource,
    ) !usize {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Deduplication: check if a route with the same first keyword already exists.
        // If it has the same response, skip registration (exact duplicate).
        // If it has a different response, replace it if the new confidence is higher.
        if (keywords.len > 0) {
            for (self.routes.items, 0..) |existing, i| {
                if (existing.keyword_count > 0 and
                    std.ascii.eqlIgnoreCase(existing.keywords[0], keywords[0]))
                {
                    if (std.mem.eql(u8, existing.response, response)) {
                        // Exact duplicate — skip
                        return i;
                    }
                    if (confidence_bp > existing.confidence_bp) {
                        // Replace with higher confidence route
                        self.allocator.free(existing.keywords[0]);
                        self.allocator.free(existing.response);
                        self.routes.items[i].keywords[0] = try self.allocator.dupe(u8, keywords[0]);
                        self.routes.items[i].response = try self.allocator.dupe(u8, response);
                        self.routes.items[i].confidence_bp = confidence_bp;
                        self.routes.items[i].category = category;
                        self.routes.items[i].source = source;
                        self.routes.items[i].created_at = std.time.timestamp();
                        self.routes.items[i].last_used = std.time.timestamp();
                        return i;
                    }
                    // Lower confidence — skip
                    return i;
                }
            }
        }

        if (self.routes.items.len >= MAX_ROUTES) {
            self.pruneLocked();
            if (self.routes.items.len >= MAX_ROUTES) return error.RegistryFull;
        }

        var route: DynamicRoute = .{
            .confidence_bp = confidence_bp,
            .category = category,
            .source = source,
            .created_at = std.time.timestamp(),
            .last_used = std.time.timestamp(),
        };

        const kw_count = @min(keywords.len, MAX_KEYWORDS);
        for (0..kw_count) |i| {
            route.keywords[i] = try self.allocator.dupe(u8, keywords[i]);
        }
        route.keyword_count = @intCast(kw_count);
        route.response = try self.allocator.dupe(u8, response);

        try self.routes.append(route);
        return self.routes.items.len - 1;
    }

    /// Registers a route with an associated conversation context topic.
    /// When matching, routes with matching context get a confidence boost.
    pub fn registerWithContext(
        self: *DynamicRouteRegistry,
        keywords: []const []const u8,
        response: []const u8,
        confidence_bp: u16,
        category: RouteCategory,
        source: RouteSource,
        context_topic: []const u8,
    ) !usize {
        const idx = try self.register(keywords, response, confidence_bp, category, source);
        self.mutex.lock();
        defer self.mutex.unlock();
        const route = &self.routes.items[idx];
        const topic_len = @min(context_topic.len, 64);
        @memcpy(route.context_topic[0..topic_len], context_topic[0..topic_len]);
        route.context_len = @intCast(topic_len);
        return idx;
    }

    pub fn match(self: *DynamicRouteRegistry, prompt: []const u8) ?DynamicRoute {
        return self.matchWithContext(prompt, null);
    }

    /// Matches routes where ANY keyword matches `keyword` (case-insensitive, word-boundary).
    /// Used for "what is X" queries where the extracted word should match any route
    /// that has it as one of its keywords, even if the route has multiple keywords.
    /// Also checks that the keyword appears in the response to ensure relevance.
    pub fn matchByKeyword(self: *DynamicRouteRegistry, keyword: []const u8) ?DynamicRoute {
        if (keyword.len < 3) return null;
        self.mutex.lock();
        defer self.mutex.unlock();

        const now = std.time.timestamp();
        var best_idx: ?usize = null;
        var best_confidence: u16 = 0;

        for (self.routes.items, 0..) |route, i| {
            var found = false;
            for (0..route.keyword_count) |k| {
                if (containsWordCI(keyword, route.keywords[k])) {
                    found = true;
                    break;
                }
            }
            if (!found) continue;
            // Relevance check: the keyword must appear in the response.
            // This prevents routes with irrelevant responses from matching
            // (e.g., a route about entanglement with "gravity" as a keyword).
            if (!containsWordCI(route.response, keyword)) continue;
            const effective_conf = route.decayedConfidence(now);
            if (effective_conf < MIN_MATCH_CONFIDENCE_BP) continue;
            if (effective_conf > best_confidence) {
                best_confidence = effective_conf;
                best_idx = i;
            }
        }

        if (best_idx) |idx| {
            self.routes.items[idx].hit_count +%= 1;
            self.routes.items[idx].last_used = now;
            return self.routes.items[idx];
        }
        return null;
    }

    pub fn matchWithContext(self: *DynamicRouteRegistry, prompt: []const u8, context_topic: ?[]const u8) ?DynamicRoute {
        self.mutex.lock();
        defer self.mutex.unlock();

        const now = std.time.timestamp();
        var best_idx: ?usize = null;
        var best_confidence: u16 = 0;

        for (self.routes.items, 0..) |route, i| {
            if (!route.matches(prompt)) continue;
            // Relevance check: the first keyword must appear in the response.
            // This prevents routes with irrelevant responses from matching.
            if (route.keyword_count > 0 and !containsWordCI(route.response, route.keywords[0])) continue;
            var effective_conf = route.decayedConfidence(now);
            if (effective_conf < MIN_MATCH_CONFIDENCE_BP) continue;

            // Context continuity boost: if route has a context topic and it matches
            // the current conversation topic, boost confidence by 1000 BP (10%)
            if (context_topic) |topic| {
                if (route.context_len > 0) {
                    const route_topic = route.context_topic[0..route.context_len];
                    if (topicEql(route_topic, topic)) {
                        effective_conf = @min(effective_conf + 1000, BP_PER_UNIT);
                    }
                }
            }

            if (effective_conf > best_confidence) {
                best_confidence = effective_conf;
                best_idx = i;
            }
        }

        if (best_idx) |idx| {
            self.routes.items[idx].hit_count +%= 1;
            self.routes.items[idx].last_used = now;
            return self.routes.items[idx];
        }
        return null;
    }

    pub fn recordEvaluation(self: *DynamicRouteRegistry, prompt: []const u8, positive: bool) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.routes.items) |*route| {
            if (route.matches(prompt)) {
                route.updateConfidence(positive);
                return;
            }
        }
    }

    pub fn pruneLowConfidence(self: *DynamicRouteRegistry) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.pruneLocked();
    }

    fn pruneLocked(self: *DynamicRouteRegistry) void {
        const now = std.time.timestamp();
        var write_idx: usize = 0;
        for (self.routes.items, 0..) |*route, read_idx| {
            const eff = route.decayedConfidence(now);
            if (eff >= PRUNE_THRESHOLD_BP) {
                if (write_idx != read_idx) {
                    self.routes.items[write_idx] = route.*;
                }
                write_idx += 1;
            } else {
                for (0..route.keyword_count) |i| {
                    self.allocator.free(route.keywords[i]);
                }
                self.allocator.free(route.response);
            }
        }
        self.routes.shrinkRetainingCapacity(write_idx);
    }

    pub fn count(self: *DynamicRouteRegistry) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.routes.items.len;
    }

    pub fn saveToFile(self: *DynamicRouteRegistry, path: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();
        var writer = file.writer();

        const n: u32 = @intCast(self.routes.items.len);
        try writer.writeInt(u32, n, .little);

        for (self.routes.items) |route| {
            try writer.writeInt(u8, route.keyword_count, .little);
            for (0..route.keyword_count) |i| {
                try writer.writeInt(u32, @intCast(route.keywords[i].len), .little);
                try writer.writeAll(route.keywords[i]);
            }
            try writer.writeInt(u32, @intCast(route.response.len), .little);
            try writer.writeAll(route.response);
            try writer.writeInt(u16, route.confidence_bp, .little);
            try writer.writeInt(u8, @intFromEnum(route.category), .little);
            try writer.writeInt(u8, @intFromEnum(route.source), .little);
            try writer.writeInt(i64, route.created_at, .little);
            try writer.writeInt(i64, route.last_used, .little);
            try writer.writeInt(u32, route.hit_count, .little);
            try writer.writeInt(u32, route.positive_eval_count, .little);
            try writer.writeInt(u32, route.negative_eval_count, .little);
            try writer.writeInt(u8, route.context_len, .little);
            if (route.context_len > 0) {
                try writer.writeAll(route.context_topic[0..route.context_len]);
            }
        }
    }

    pub fn loadFromFile(self: *DynamicRouteRegistry, path: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const file = std.fs.cwd().openFile(path, .{}) catch return;
        defer file.close();
        var reader = file.reader();

        const n = try reader.readInt(u32, .little);
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            var route: DynamicRoute = .{};

            route.keyword_count = try reader.readInt(u8, .little);
            var j: u8 = 0;
            while (j < route.keyword_count) : (j += 1) {
                const kw_len = try reader.readInt(u32, .little);
                const kw_buf = try self.allocator.alloc(u8, kw_len);
                _ = try reader.readAll(kw_buf);
                route.keywords[j] = kw_buf;
            }

            const resp_len = try reader.readInt(u32, .little);
            const resp_buf = try self.allocator.alloc(u8, resp_len);
            _ = try reader.readAll(resp_buf);
            route.response = resp_buf;

            route.confidence_bp = try reader.readInt(u16, .little);
            route.category = @enumFromInt(try reader.readInt(u8, .little));
            route.source = @enumFromInt(try reader.readInt(u8, .little));
            route.created_at = try reader.readInt(i64, .little);
            route.last_used = try reader.readInt(i64, .little);
            route.hit_count = try reader.readInt(u32, .little);
            route.positive_eval_count = try reader.readInt(u32, .little);
            route.negative_eval_count = try reader.readInt(u32, .little);
            route.context_len = try reader.readInt(u8, .little);
            if (route.context_len > 0) {
                if (route.context_len > 64) return error.InvalidData;
                _ = try reader.readAll(route.context_topic[0..route.context_len]);
            }

            try self.routes.append(route);
        }
    }

    /// Serializes all routes to a binary buffer for network sync (e.g. Maple push).
    pub fn saveToBuffer(self: *DynamicRouteRegistry, allocator: std.mem.Allocator) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        var buf = std.ArrayList(u8).init(allocator);
        errdefer buf.deinit();

        const n: u32 = @intCast(self.routes.items.len);
        try buf.appendSlice(std.mem.asBytes(&n));

        for (self.routes.items) |route| {
            try buf.appendSlice(std.mem.asBytes(&route.keyword_count));
            for (0..route.keyword_count) |i| {
                const kw_len: u32 = @intCast(route.keywords[i].len);
                try buf.appendSlice(std.mem.asBytes(&kw_len));
                try buf.appendSlice(route.keywords[i]);
            }
            const resp_len: u32 = @intCast(route.response.len);
            try buf.appendSlice(std.mem.asBytes(&resp_len));
            try buf.appendSlice(route.response);
            try buf.appendSlice(std.mem.asBytes(&route.confidence_bp));
            try buf.append(@as(u8, @intCast(@intFromEnum(route.category))));
            try buf.append(@as(u8, @intCast(@intFromEnum(route.source))));
            try buf.appendSlice(std.mem.asBytes(&route.created_at));
            try buf.appendSlice(std.mem.asBytes(&route.last_used));
            try buf.appendSlice(std.mem.asBytes(&route.hit_count));
            try buf.appendSlice(std.mem.asBytes(&route.positive_eval_count));
            try buf.appendSlice(std.mem.asBytes(&route.negative_eval_count));
            try buf.append(route.context_len);
            if (route.context_len > 0) {
                try buf.appendSlice(route.context_topic[0..route.context_len]);
            }
        }

        return try buf.toOwnedSlice();
    }

    /// Deserializes routes from a binary buffer (e.g. received from Maple mesh).
    /// Replaces all existing routes.
    pub fn loadFromBuffer(self: *DynamicRouteRegistry, data: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Free existing routes
        for (self.routes.items) |*route| {
            for (0..route.keyword_count) |i| {
                self.allocator.free(route.keywords[i]);
            }
            self.allocator.free(route.response);
        }
        self.routes.clearRetainingCapacity();

        if (data.len < 4) return;
        var pos: usize = 0;
        const n = std.mem.readInt(u32, data[pos..][0..4], .little);
        pos += 4;

        var i: u32 = 0;
        while (i < n) : (i += 1) {
            if (pos + 1 > data.len) return error.TruncatedData;
            var route: DynamicRoute = .{};

            route.keyword_count = data[pos];
            pos += 1;

            var j: u8 = 0;
            while (j < route.keyword_count) : (j += 1) {
                if (pos + 4 > data.len) return error.TruncatedData;
                const kw_len = std.mem.readInt(u32, data[pos..][0..4], .little);
                pos += 4;
                if (pos + kw_len > data.len) return error.TruncatedData;
                const kw_buf = try self.allocator.alloc(u8, kw_len);
                @memcpy(kw_buf, data[pos..][0..kw_len]);
                route.keywords[j] = kw_buf;
                pos += kw_len;
            }

            if (pos + 4 > data.len) return error.TruncatedData;
            const resp_len = std.mem.readInt(u32, data[pos..][0..4], .little);
            pos += 4;
            if (pos + resp_len > data.len) return error.TruncatedData;
            const resp_buf = try self.allocator.alloc(u8, resp_len);
            @memcpy(resp_buf, data[pos..][0..resp_len]);
            route.response = resp_buf;
            pos += resp_len;

            if (pos + 2 > data.len) return error.TruncatedData;
            route.confidence_bp = std.mem.readInt(u16, data[pos..][0..2], .little);
            pos += 2;

            if (pos + 1 > data.len) return error.TruncatedData;
            route.category = @enumFromInt(data[pos]);
            pos += 1;

            if (pos + 1 > data.len) return error.TruncatedData;
            route.source = @enumFromInt(data[pos]);
            pos += 1;

            if (pos + 8 > data.len) return error.TruncatedData;
            route.created_at = std.mem.readInt(i64, data[pos..][0..8], .little);
            pos += 8;

            if (pos + 8 > data.len) return error.TruncatedData;
            route.last_used = std.mem.readInt(i64, data[pos..][0..8], .little);
            pos += 8;

            if (pos + 4 > data.len) return error.TruncatedData;
            route.hit_count = std.mem.readInt(u32, data[pos..][0..4], .little);
            pos += 4;

            if (pos + 4 > data.len) return error.TruncatedData;
            route.positive_eval_count = std.mem.readInt(u32, data[pos..][0..4], .little);
            pos += 4;

            if (pos + 4 > data.len) return error.TruncatedData;
            route.negative_eval_count = std.mem.readInt(u32, data[pos..][0..4], .little);
            pos += 4;

            if (pos + 1 > data.len) return error.TruncatedData;
            route.context_len = data[pos];
            pos += 1;
            if (route.context_len > 64) return error.InvalidData;
            if (route.context_len > 0) {
                if (pos + route.context_len > data.len) return error.TruncatedData;
                @memcpy(route.context_topic[0..route.context_len], data[pos..][0..route.context_len]);
                pos += route.context_len;
            }

            try self.routes.append(route);
        }
    }
};

pub const QueryRouter = struct {
    registry: *DynamicRouteRegistry,
    min_confidence_bp: u16 = HIGH_CONFIDENCE_BP,
    experience_log: std.ArrayList(ExperienceEntry),
    allocator: std.mem.Allocator,

    pub const ExperienceEntry = struct {
        prompt_hash: u64,
        used_dynamic_route: bool,
        response_score_bp: u16,
    };

    pub fn init(allocator: std.mem.Allocator, registry: *DynamicRouteRegistry) QueryRouter {
        return .{
            .registry = registry,
            .experience_log = std.ArrayList(ExperienceEntry).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *QueryRouter) void {
        self.experience_log.deinit();
    }

    pub fn shouldUseDynamicRoute(self: *QueryRouter, prompt: []const u8, kg_score_skewness: f64) bool {
        if (kg_score_skewness > 0.6) {
            if (self.registry.match(prompt)) |route| {
                if (route.confidence_bp >= self.min_confidence_bp) return true;
            }
        }
        return false;
    }

    pub fn recordExperience(self: *QueryRouter, prompt_hash: u64, used_dynamic: bool, score_bp: u16) !void {
        try self.experience_log.append(.{
            .prompt_hash = prompt_hash,
            .used_dynamic_route = used_dynamic,
            .response_score_bp = score_bp,
        });
        if (self.experience_log.items.len > 256) {
            const len = self.experience_log.items.len;
            for (1..len) |i| {
                self.experience_log.items[i - 1] = self.experience_log.items[i];
            }
            self.experience_log.shrinkRetainingCapacity(len - 1);
        }
    }

    pub fn dynamicRoutePerformance(self: QueryRouter) f64 {
        if (self.experience_log.items.len == 0) return 0.0;
        var dynamic_sum: f64 = 0.0;
        var dynamic_count: f64 = 0.0;
        var fallback_sum: f64 = 0.0;
        var fallback_count: f64 = 0.0;
        for (self.experience_log.items) |exp| {
            const score_f = @as(f64, @floatFromInt(exp.response_score_bp)) / @as(f64, @floatFromInt(BP_PER_UNIT));
            if (exp.used_dynamic_route) {
                dynamic_sum += score_f;
                dynamic_count += 1.0;
            } else {
                fallback_sum += score_f;
                fallback_count += 1.0;
            }
        }
        if (dynamic_count == 0) return 0.0;
        const dynamic_avg = dynamic_sum / dynamic_count;
        if (fallback_count == 0) return dynamic_avg;
        const fallback_avg = fallback_sum / fallback_count;
        return dynamic_avg - fallback_avg;
    }

    pub fn adjustThreshold(self: *QueryRouter) void {
        const perf = self.dynamicRoutePerformance();
        if (perf > 0.1) {
            self.min_confidence_bp = @max(MIN_MATCH_CONFIDENCE_BP, self.min_confidence_bp - 100);
        } else if (perf < -0.1) {
            self.min_confidence_bp = @min(BP_PER_UNIT, self.min_confidence_bp + 100);
        }
    }
};

test "DynamicRouteRegistry: init and deinit" {
    var reg = DynamicRouteRegistry.init(std.testing.allocator);
    defer reg.deinit();
    try std.testing.expectEqual(@as(usize, 0), reg.count());
}

test "DynamicRouteRegistry: register and match" {
    var reg = DynamicRouteRegistry.init(std.testing.allocator);
    defer reg.deinit();

    const kws = [_][]const u8{ "photosynthesis", "plants" };
    _ = try reg.register(&kws, "Plants use photosynthesis to make food.", DEFAULT_CORPUS_CONFIDENCE_BP, .factual, .corpus_extracted);

    try std.testing.expectEqual(@as(usize, 1), reg.count());

    const matched = reg.match("How do plants use photosynthesis?");
    try std.testing.expect(matched != null);
    try std.testing.expect(matched.?.hit_count == 1);
}

test "DynamicRouteRegistry: no match returns null" {
    var reg = DynamicRouteRegistry.init(std.testing.allocator);
    defer reg.deinit();

    const kws = [_][]const u8{ "quantum", "mechanics" };
    _ = try reg.register(&kws, "Quantum mechanics is physics.", DEFAULT_CORPUS_CONFIDENCE_BP, .factual, .corpus_extracted);

    try std.testing.expect(reg.match("How does a car engine work?") == null);
}

test "DynamicRouteRegistry: highest confidence wins" {
    var reg = DynamicRouteRegistry.init(std.testing.allocator);
    defer reg.deinit();

    const kws1 = [_][]const u8{"gravity"};
    _ = try reg.register(&kws1, "Gravity is a weak force.", 5200, .factual, .corpus_extracted);

    const kws2 = [_][]const u8{"gravity"};
    _ = try reg.register(&kws2, "Gravity is a fundamental force of nature.", 9000, .factual, .openai_reinforced);

    // Deduplication: same first keyword replaces with higher confidence
    try std.testing.expectEqual(@as(usize, 1), reg.count());

    const matched = reg.match("What is gravity?");
    try std.testing.expect(matched != null);
    try std.testing.expect(matched.?.confidence_bp == 9000);
}

test "DynamicRouteRegistry: recordEvaluation updates confidence" {
    var reg = DynamicRouteRegistry.init(std.testing.allocator);
    defer reg.deinit();

    const kws = [_][]const u8{"evolution"};
    _ = try reg.register(&kws, "Evolution is change over time.", 6000, .factual, .corpus_extracted);

    reg.recordEvaluation("Tell me about evolution", true);
    try std.testing.expect(reg.routes.items[0].positive_eval_count == 1);
    try std.testing.expect(reg.routes.items[0].confidence_bp > 6000);
}

test "DynamicRouteRegistry: save and load" {
    const test_path = "test_dynamic_routes.bin";
    defer std.fs.cwd().deleteFile(test_path) catch {};

    {
        var reg = DynamicRouteRegistry.init(std.testing.allocator);
        defer reg.deinit();

        const kws = [_][]const u8{ "black", "hole" };
        _ = try reg.register(&kws, "Black holes are regions of extreme gravity.", 7500, .factual, .kg_synthesized);
        try reg.saveToFile(test_path);
    }

    var reg2 = DynamicRouteRegistry.init(std.testing.allocator);
    defer reg2.deinit();
    try reg2.loadFromFile(test_path);
    try std.testing.expectEqual(@as(usize, 1), reg2.count());

    const matched = reg2.match("What is a black hole?");
    try std.testing.expect(matched != null);
    try std.testing.expect(matched.?.confidence_bp == 7500);
}

test "DynamicRouteRegistry: pruneLowConfidence removes low routes" {
    var reg = DynamicRouteRegistry.init(std.testing.allocator);
    defer reg.deinit();

    const kws1 = [_][]const u8{"low"};
    _ = try reg.register(&kws1, "Low confidence route.", 2500, .factual, .corpus_extracted);

    const kws2 = [_][]const u8{"high"};
    _ = try reg.register(&kws2, "High confidence route.", 9000, .factual, .openai_reinforced);

    try std.testing.expectEqual(@as(usize, 2), reg.count());
    reg.pruneLowConfidence();
    try std.testing.expectEqual(@as(usize, 1), reg.count());
}

test "DynamicRoute: decayedConfidence reduces over time" {
    const now: i64 = 1000000;
    var route = DynamicRoute{
        .confidence_bp = 8000,
        .last_used = now - 86400 * 10,
    };
    const decayed = route.decayedConfidence(now);
    try std.testing.expect(decayed < 8000);
    try std.testing.expect(decayed == 8000 - 10 * CONFIDENCE_DECAY_PER_DAY_BP);
}

test "DynamicRoute: updateConfidence positive and negative" {
    var route = DynamicRoute{ .confidence_bp = 5000 };
    route.updateConfidence(true);
    try std.testing.expect(route.confidence_bp > 5000);
    try std.testing.expect(route.positive_eval_count == 1);

    route.updateConfidence(false);
    try std.testing.expect(route.confidence_bp < route.confidence_bp + 300);
    try std.testing.expect(route.negative_eval_count == 1);
}

test "QueryRouter: shouldUseDynamicRoute with high skewness" {
    var reg = DynamicRouteRegistry.init(std.testing.allocator);
    defer reg.deinit();

    const kws = [_][]const u8{"DNA"};
    _ = try reg.register(&kws, "DNA carries genetic info.", 9000, .factual, .openai_reinforced);

    var router = QueryRouter.init(std.testing.allocator, &reg);
    defer router.deinit();

    try std.testing.expect(router.shouldUseDynamicRoute("What is DNA?", 0.8));
    try std.testing.expect(!router.shouldUseDynamicRoute("What is DNA?", 0.3));
}

test "QueryRouter: recordExperience and performance" {
    var reg = DynamicRouteRegistry.init(std.testing.allocator);
    defer reg.deinit();

    var router = QueryRouter.init(std.testing.allocator, &reg);
    defer router.deinit();

    try router.recordExperience(1, true, 8000);
    try router.recordExperience(2, false, 5000);
    try router.recordExperience(3, true, 7500);

    const perf = router.dynamicRoutePerformance();
    try std.testing.expect(perf > 0.0);
}

test "QueryRouter: adjustThreshold lowers when dynamic performs well" {
    var reg = DynamicRouteRegistry.init(std.testing.allocator);
    defer reg.deinit();

    var router = QueryRouter.init(std.testing.allocator, &reg);
    defer router.deinit();

    const initial = router.min_confidence_bp;
    try router.recordExperience(1, true, 9000);
    try router.recordExperience(2, false, 4000);
    router.adjustThreshold();
    try std.testing.expect(router.min_confidence_bp < initial);
}

test "DynamicRouteRegistry: saveToBuffer and loadFromBuffer round-trip" {
    var reg = DynamicRouteRegistry.init(std.testing.allocator);
    defer reg.deinit();

    const kws1 = [_][]const u8{ "photosynthesis", "plants" };
    _ = try reg.register(&kws1, "Photosynthesis is how plants make food.", 7500, .factual, .corpus_extracted);

    const kws2 = [_][]const u8{ "DNA", "genetics" };
    _ = try reg.register(&kws2, "DNA carries genetic information.", 8000, .factual, .kg_synthesized);

    try std.testing.expectEqual(@as(usize, 2), reg.count());

    const buf = try reg.saveToBuffer(std.testing.allocator);
    defer std.testing.allocator.free(buf);
    try std.testing.expect(buf.len > 0);

    var reg2 = DynamicRouteRegistry.init(std.testing.allocator);
    defer reg2.deinit();
    try reg2.loadFromBuffer(buf);
    try std.testing.expectEqual(@as(usize, 2), reg2.count());

    const matched = reg2.match("How does photosynthesis work in plants?");
    try std.testing.expect(matched != null);
    try std.testing.expectEqualStrings("Photosynthesis is how plants make food.", matched.?.response);
}

test "DynamicRouteRegistry: registerWithContext and matchWithContext boost" {
    var reg = DynamicRouteRegistry.init(std.testing.allocator);
    defer reg.deinit();

    const kws = [_][]const u8{ "gravity", "architecture" };
    _ = try reg.registerWithContext(&kws, "Gravity manipulation enables floating cities.", 6000, .creative, .openai_reinforced, "physics");

    // Without context: should match (6000 >= MIN_MATCH_CONFIDENCE_BP=5000)
    const matched_no_ctx = reg.match("If humans could manipulate gravity in architecture?");
    try std.testing.expect(matched_no_ctx != null);

    // With matching context: should also match and get boost
    const matched_with_ctx = reg.matchWithContext("If humans could manipulate gravity in architecture?", "physics");
    try std.testing.expect(matched_with_ctx != null);

    // With non-matching context: should still match (no boost, but 6000 >= 5000)
    const matched_other_ctx = reg.matchWithContext("If humans could manipulate gravity in architecture?", "biology");
    try std.testing.expect(matched_other_ctx != null);
}

test "DynamicRouteRegistry: saveToBuffer/loadFromBuffer with context topic" {
    var reg = DynamicRouteRegistry.init(std.testing.allocator);
    defer reg.deinit();

    const kws = [_][]const u8{ "entropy", "thermodynamics" };
    _ = try reg.registerWithContext(&kws, "Entropy increases in isolated systems.", 8500, .factual, .openai_reinforced, "physics");

    const buf = try reg.saveToBuffer(std.testing.allocator);
    defer std.testing.allocator.free(buf);

    var reg2 = DynamicRouteRegistry.init(std.testing.allocator);
    defer reg2.deinit();
    try reg2.loadFromBuffer(buf);

    try std.testing.expectEqual(@as(usize, 1), reg2.count());
    const matched = reg2.match("How does entropy relate to thermodynamics?");
    try std.testing.expect(matched != null);
    try std.testing.expectEqualStrings("Entropy increases in isolated systems.", matched.?.response);
    try std.testing.expect(matched.?.context_len == 7);
    try std.testing.expectEqualSlices(u8, "physics", matched.?.context_topic[0..matched.?.context_len]);
}

// =============================================================================
// Framework Route Detection (E=mc²-i-E=mc⁻² toy-model tuning)
// =============================================================================

/// Framework keywords that indicate a framework_query route category.
/// These keywords match the framework's mathematical structure and concepts.
pub const FRAMEWORK_KEYWORDS = [_][]const u8{
    "421",                "7-defect",            "1/8",               "C=2",
    "E=mc²",             "E=mc^-2",             "octonion",          "E0 lattice",
    "Fano plane",         "Mobius",              "Möbius",           "phi cooling",
    "golden ratio",       "generative chain",    "0^0=i",             "Cayley-Dickson",
    "Jordan algebra",     "J3(O)",               "SO(10)",            "E8 roots",
    "240 roots",          "16³",                "15³",              "721",
    "shell transition",   "surface computation", "scaling chain",     "consciousness aperture",
    "self-recognition",   "e6",                  "observer-observed", "Higgs",
    "fermion",            "spinor",              "coupling constant", "bandwidth C",
    "dimensional ladder",
};

/// Detects whether a prompt contains framework keywords and should be
/// classified as a framework_query route category.
pub fn isFrameworkQuery(prompt: []const u8) bool {
    for (FRAMEWORK_KEYWORDS) |keyword| {
        if (std.mem.indexOf(u8, prompt, keyword) != null) return true;
    }
    return false;
}

/// Classifies a prompt into a route category, with framework detection.
pub fn classifyPrompt(prompt: []const u8) RouteCategory {
    if (isFrameworkQuery(prompt)) return .framework_query;
    // Default to open_ended for unclassified prompts
    return .open_ended;
}

test "framework: detect framework query keywords" {
    try std.testing.expect(isFrameworkQuery("What is the 421 identity?"));
    try std.testing.expect(isFrameworkQuery("Explain the 7-defect"));
    try std.testing.expect(isFrameworkQuery("How does the E0 lattice work?"));
    try std.testing.expect(isFrameworkQuery("What is C=2 consciousness?"));
    try std.testing.expect(!isFrameworkQuery("What is the weather today?"));
    try std.testing.expect(!isFrameworkQuery("Tell me a joke"));
}

test "framework: classify prompt with framework detection" {
    try std.testing.expectEqual(RouteCategory.framework_query, classifyPrompt("What is the 421 identity?"));
    try std.testing.expectEqual(RouteCategory.framework_query, classifyPrompt("Explain the octonion multiplication"));
    try std.testing.expectEqual(RouteCategory.open_ended, classifyPrompt("Hello there"));
}
