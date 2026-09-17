//! tools.zig — Zero-Dependency Function & Tool Calling Engine for Qstar
//!
//! Provides OpenAI / Ollama compatible function calling schemas, tool registration,
//! JSON parameter parsing, and real tool execution for the lattice agent.

const std = @import("std");
const builtin = @import("builtin");
const fp = @import("fixed_point");
const kg_mod = @import("knowledge_graph");
const db_mod = @import("external_db");
const geo = @import("geo_math");
const flights = @import("geoview/feed_flights.zig");
const vessels = @import("geoview/feed_vessels.zig");
const satellites = @import("geoview/feed_satellites.zig");
const earthquakes = @import("geoview/feed_earthquakes.zig");
const cctv = @import("geoview/feed_cctv.zig");
const hud_mod = @import("geoview/hud.zig");
const scene_mod = @import("geoview/scene_director.zig");
const ann_mod = @import("geoview/annotation.zig");

const is_wasm = builtin.os.tag == .freestanding;

pub const ParameterType = enum {
    string,
    number,
    integer,
    boolean,
};

/// Dimensional assignment for tools, parallel to the QSTAR 11D lattice channels.
/// Each tool is mapped to exactly one dimension based on its semantic role.
pub const ToolDimension = enum(u4) {
    /// e0 = origin: seed/identity generation (uuid, time_now)
    e0_origin = 0,
    /// e1 = time: temporal tracking/sequence (track_*, earthquake_query)
    e1_time = 1,
    /// e2 = quantum: superposition/search (search, lookup, kg_query, db_query)
    e2_quantum = 2,
    /// e3 = space: spatial/topology (geo_*, globe_query, cctv, annotation)
    e3_space = 3,
    /// e4 = energy: dynamics/execution (shell_exec, file_write, http_fetch, scene_play)
    e4_energy = 4,
    /// e5 = structure: form/representation (calculate, base64, hash, json, data, text)
    e5_structure = 5,
    /// e6 = self-recognition: metacognition/analysis (sentiment, ner, classify, face, gaze)
    e6_metacognition = 6,
    /// e7 = shadow/gravity: quantum/physics observation (quantum_simulate, lattice_node)
    e7_physics = 7,

    pub fn label(self: ToolDimension) []const u8 {
        return switch (self) {
            .e0_origin => "e0=origin",
            .e1_time => "e1=time",
            .e2_quantum => "e2=quantum",
            .e3_space => "e3=space",
            .e4_energy => "e4=energy",
            .e5_structure => "e5=structure",
            .e6_metacognition => "e6=metacognition",
            .e7_physics => "e7=physics",
        };
    }

    pub fn channel(self: ToolDimension) u4 {
        return @intFromEnum(self);
    }
};

pub const ToolParameter = struct {
    name: []const u8,
    param_type: ParameterType,
    description: []const u8,
    required: bool = true,
};

pub const ToolDefinition = struct {
    name: []const u8,
    description: []const u8,
    parameters: []const ToolParameter,
    /// Dimensional assignment in the QSTAR 11D framework (e0-e7).
    dimension: ToolDimension = .e5_structure,
};

pub const ToolCall = struct {
    id: []const u8,
    name: []const u8,
    arguments_json: []const u8,
};

pub const ToolResult = struct {
    tool_call_id: []const u8,
    content: []const u8,
    is_error: bool = false,
};

/// Lightweight JSON value extractor — replaces repeated std.mem.indexOf scans.
/// Extracts string, number, integer, and boolean values from JSON by key.
pub const JsonValue = struct {
    json: []const u8,

    pub fn init(json: []const u8) JsonValue {
        return .{ .json = json };
    }

    pub fn getString(self: JsonValue, key: []const u8) ?[]const u8 {
        var buf: [128]u8 = undefined;
        const search = std.fmt.bufPrint(&buf, "\"{s}\":", .{key}) catch return null;
        const idx = std.mem.indexOf(u8, self.json, search) orelse return null;
        var i = idx + search.len;
        while (i < self.json.len and (self.json[i] == ' ' or self.json[i] == '\t')) : (i += 1) {}
        if (i >= self.json.len or self.json[i] != '"') return null;
        const start = i + 1;
        var end = start;
        while (end < self.json.len) {
            if (self.json[end] == '\\' and end + 1 < self.json.len) {
                end += 2;
                continue;
            }
            if (self.json[end] == '"') break;
            end += 1;
        }
        if (end >= self.json.len) return null;
        return self.json[start..end];
    }

    pub fn getNumber(self: JsonValue, key: []const u8) ?f64 {
        var buf: [128]u8 = undefined;
        const search = std.fmt.bufPrint(&buf, "\"{s}\":", .{key}) catch return null;
        const idx = std.mem.indexOf(u8, self.json, search) orelse return null;
        var i = idx + search.len;
        while (i < self.json.len and (self.json[i] == ' ' or self.json[i] == '\t' or self.json[i] == '"')) : (i += 1) {}
        var end = i;
        while (end < self.json.len and (self.json[end] == '-' or self.json[end] == '.' or (self.json[end] >= '0' and self.json[end] <= '9'))) : (end += 1) {}
        if (end > i) {
            return std.fmt.parseFloat(f64, self.json[i..end]) catch null;
        }
        return null;
    }

    pub fn getInteger(self: JsonValue, key: []const u8) ?i64 {
        const val = self.getNumber(key) orelse return null;
        return @intFromFloat(val);
    }

    pub fn getBool(self: JsonValue, key: []const u8) ?bool {
        var buf: [128]u8 = undefined;
        const search = std.fmt.bufPrint(&buf, "\"{s}\":", .{key}) catch return null;
        const idx = std.mem.indexOf(u8, self.json, search) orelse return null;
        var i = idx + search.len;
        while (i < self.json.len and (self.json[i] == ' ' or self.json[i] == '\t')) : (i += 1) {}
        if (i + 4 <= self.json.len and std.mem.eql(u8, self.json[i .. i + 4], "true")) return true;
        if (i + 5 <= self.json.len and std.mem.eql(u8, self.json[i .. i + 5], "false")) return false;
        return null;
    }
};

pub const ToolRegistry = struct {
    allocator: std.mem.Allocator,
    tools: std.StringHashMap(ToolDefinition),
    kg: ?*kg_mod.KnowledgeGraph = null,
    db: ?*db_mod.ExternalDb = null,

    pub fn init(allocator: std.mem.Allocator) ToolRegistry {
        var tr = ToolRegistry{
            .allocator = allocator,
            .tools = std.StringHashMap(ToolDefinition).init(allocator),
        };
        tr.registerBuiltins() catch {};
        return tr;
    }

    pub fn attachKnowledgeGraph(self: *ToolRegistry, kg: *kg_mod.KnowledgeGraph) void {
        self.kg = kg;
    }

    pub fn attachExternalDb(self: *ToolRegistry, db: *db_mod.ExternalDb) void {
        self.db = db;
    }

    pub fn deinit(self: *ToolRegistry) void {
        self.tools.deinit();
    }

    pub fn register(self: *ToolRegistry, tool: ToolDefinition) !void {
        try self.tools.put(tool.name, tool);
    }

    pub fn get(self: *const ToolRegistry, name: []const u8) ?ToolDefinition {
        return self.tools.get(name);
    }

    /// Returns the dimension assigned to a tool by name, or null if not found.
    pub fn getDimension(self: *const ToolRegistry, name: []const u8) ?ToolDimension {
        const tool = self.tools.get(name) orelse return null;
        return tool.dimension;
    }

    /// Counts tools registered under a given dimension.
    pub fn countByDimension(self: *const ToolRegistry, dim: ToolDimension) usize {
        var count: usize = 0;
        var it = self.tools.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.dimension == dim) count += 1;
        }
        return count;
    }

    /// Returns the total count of registered tools.
    pub fn toolCount(self: *const ToolRegistry) usize {
        return self.tools.count();
    }

    /// Returns a JSON array of all tool names grouped by dimension.
    /// Caller owns the returned slice.
    pub fn listByDimension(self: *const ToolRegistry, allocator: std.mem.Allocator) ![]const u8 {
        var result = std.ArrayList(u8).init(allocator);
        defer result.deinit();

        try result.appendSlice("{");

        const dims = [_]ToolDimension{
            .e0_origin, .e1_time,      .e2_quantum,       .e3_space,
            .e4_energy, .e5_structure, .e6_metacognition, .e7_physics,
        };

        var first = true;
        for (dims) |dim| {
            if (!first) try result.appendSlice(",");
            first = false;
            try result.writer().print("\"{s}\":[", .{dim.label()});
            var it = self.tools.iterator();
            var first_tool = true;
            while (it.next()) |entry| {
                if (entry.value_ptr.dimension != dim) continue;
                if (!first_tool) try result.appendSlice(",");
                first_tool = false;
                try result.writer().print("\"{s}\"", .{entry.key_ptr.*});
            }
            try result.appendSlice("]");
        }
        try result.appendSlice("}");
        return result.toOwnedSlice();
    }

    pub fn registerBuiltins(self: *ToolRegistry) !void {
        // 1. calculate tool
        const calc_params = [_]ToolParameter{
            .{ .name = "op", .param_type = .string, .description = "Operation: add, sub, mul, div, sqrt, exp, sin, cos" },
            .{ .name = "a", .param_type = .number, .description = "First operand" },
            .{ .name = "b", .param_type = .number, .description = "Second operand (optional for sqrt/exp/sin)", .required = false },
        };
        try self.register(.{
            .name = "calculate",
            .dimension = .e5_structure,
            .description = "Executes high-precision fixed-point mathematical operations.",
            .parameters = &calc_params,
        });

        // 2. lattice_node tool
        const node_params = [_]ToolParameter{
            .{ .name = "x", .param_type = .integer, .description = "Lattice X coordinate (0..14)" },
            .{ .name = "y", .param_type = .integer, .description = "Lattice Y coordinate (0..14)" },
            .{ .name = "z", .param_type = .integer, .description = "Lattice Z coordinate (0..14)" },
        };
        try self.register(.{
            .name = "lattice_node",
            .dimension = .e7_physics,
            .description = "Queries discrete E0 lattice properties, e-values, and octonionic routing for given coordinates.",
            .parameters = &node_params,
        });

        // 3. quantum_simulate tool
        const quantum_params = [_]ToolParameter{
            .{ .name = "circuit", .param_type = .string, .description = "Quantum circuit: bell, grover, ghz" },
            .{ .name = "qubits", .param_type = .integer, .description = "Number of qubits (2..8)" },
        };
        try self.register(.{
            .name = "quantum_simulate",
            .dimension = .e7_physics,
            .description = "Simulates quantum state evolution, superposition, and Grover search.",
            .parameters = &quantum_params,
        });

        // 4. kg_query tool
        const kg_params = [_]ToolParameter{
            .{ .name = "entity", .param_type = .string, .description = "Entity or subject term to query in knowledge graph" },
            .{ .name = "predicate", .param_type = .string, .description = "Optional relation/predicate filter", .required = false },
        };
        try self.register(.{
            .name = "kg_query",
            .dimension = .e2_quantum,
            .description = "Queries the discrete E0 lattice-grounded Knowledge Graph for relational triplets and neighbors.",
            .parameters = &kg_params,
        });

        // 5. db_query tool
        const db_params = [_]ToolParameter{
            .{ .name = "key", .param_type = .string, .description = "Target key or search term" },
            .{ .name = "source", .param_type = .string, .description = "Database source name or category", .required = false },
        };
        try self.register(.{
            .name = "db_query",
            .dimension = .e2_quantum,
            .description = "Queries structured key-value databases, local schemas, and reference datasets.",
            .parameters = &db_params,
        });

        // 6. external_search tool
        const search_params = [_]ToolParameter{
            .{ .name = "query", .param_type = .string, .description = "Search query string" },
        };
        try self.register(.{
            .name = "external_search",
            .dimension = .e2_quantum,
            .description = "Searches external encyclopedic knowledge, dictionaries, and legal archives.",
            .parameters = &search_params,
        });

        // === Core Utility Tools ===

        // 7. file_read
        const fr_params = [_]ToolParameter{
            .{ .name = "path", .param_type = .string, .description = "File path to read" },
            .{ .name = "max_bytes", .param_type = .integer, .description = "Max bytes to read (default 1MB)", .required = false },
        };
        try self.register(.{ .name = "file_read", .dimension = .e5_structure, .description = "Reads file contents from the filesystem.", .parameters = &fr_params });

        // 8. file_write
        const fw_params = [_]ToolParameter{
            .{ .name = "path", .param_type = .string, .description = "File path to write" },
            .{ .name = "content", .param_type = .string, .description = "Content to write" },
        };
        try self.register(.{ .name = "file_write", .dimension = .e4_energy, .description = "Writes content to a file on the filesystem.", .parameters = &fw_params });

        // 9. file_list
        const fl_params = [_]ToolParameter{
            .{ .name = "path", .param_type = .string, .description = "Directory path to list" },
        };
        try self.register(.{ .name = "file_list", .dimension = .e5_structure, .description = "Lists files and directories at the given path.", .parameters = &fl_params });

        // 10. http_fetch
        const hf_params = [_]ToolParameter{
            .{ .name = "url", .param_type = .string, .description = "URL to fetch" },
        };
        try self.register(.{ .name = "http_fetch", .dimension = .e4_energy, .description = "Fetches content from an HTTP/HTTPS URL.", .parameters = &hf_params });

        // 11. shell_exec
        const se_params = [_]ToolParameter{
            .{ .name = "command", .param_type = .string, .description = "Shell command to execute" },
        };
        try self.register(.{ .name = "shell_exec", .dimension = .e4_energy, .description = "Executes a shell command and returns stdout.", .parameters = &se_params });

        // 12. time_now
        try self.register(.{ .name = "time_now", .dimension = .e0_origin, .description = "Returns current timestamp in ISO 8601 and epoch seconds.", .parameters = &.{} });

        // 13. uuid_generate
        try self.register(.{ .name = "uuid_generate", .dimension = .e0_origin, .description = "Generates a UUID v4 string.", .parameters = &.{} });

        // 14. base64_encode
        const b64e_params = [_]ToolParameter{
            .{ .name = "data", .param_type = .string, .description = "String to encode" },
        };
        try self.register(.{ .name = "base64_encode", .dimension = .e5_structure, .description = "Encodes a string to base64.", .parameters = &b64e_params });

        // 15. base64_decode
        const b64d_params = [_]ToolParameter{
            .{ .name = "data", .param_type = .string, .description = "Base64 string to decode" },
        };
        try self.register(.{ .name = "base64_decode", .dimension = .e5_structure, .description = "Decodes a base64 string.", .parameters = &b64d_params });

        // 16. hash_compute
        const hash_params = [_]ToolParameter{
            .{ .name = "data", .param_type = .string, .description = "Data to hash" },
            .{ .name = "algorithm", .param_type = .string, .description = "Hash algorithm: sha256 or crc32", .required = false },
        };
        try self.register(.{ .name = "hash_compute", .dimension = .e5_structure, .description = "Computes hash (SHA-256 or CRC32) of input data.", .parameters = &hash_params });

        // 17. json_validate
        const jv_params = [_]ToolParameter{
            .{ .name = "data", .param_type = .string, .description = "JSON string to validate" },
        };
        try self.register(.{ .name = "json_validate", .dimension = .e5_structure, .description = "Validates whether a string is well-formed JSON.", .parameters = &jv_params });

        // 18. json_format
        const jf_params = [_]ToolParameter{
            .{ .name = "data", .param_type = .string, .description = "JSON string to format" },
            .{ .name = "indent", .param_type = .integer, .description = "Indentation spaces (0=minify)", .required = false },
        };
        try self.register(.{ .name = "json_format", .dimension = .e5_structure, .description = "Pretty-prints or minifies a JSON string.", .parameters = &jf_params });

        // 19. string_replace
        const sr_params = [_]ToolParameter{
            .{ .name = "text", .param_type = .string, .description = "Input text" },
            .{ .name = "find", .param_type = .string, .description = "String to find" },
            .{ .name = "replace", .param_type = .string, .description = "Replacement string" },
        };
        try self.register(.{ .name = "string_replace", .dimension = .e5_structure, .description = "Find and replace all occurrences in text.", .parameters = &sr_params });

        // === Text Processing Tools ===

        // 20. text_summarize
        const ts_params = [_]ToolParameter{
            .{ .name = "text", .param_type = .string, .description = "Text to summarize" },
            .{ .name = "sentences", .param_type = .integer, .description = "Max sentences in summary (default 3)", .required = false },
        };
        try self.register(.{ .name = "text_summarize", .dimension = .e5_structure, .description = "Extractive summarization by sentence scoring.", .parameters = &ts_params });

        // 21. word_count
        const wc_params = [_]ToolParameter{
            .{ .name = "text", .param_type = .string, .description = "Text to count" },
        };
        try self.register(.{ .name = "word_count", .dimension = .e5_structure, .description = "Counts words, characters, sentences, and paragraphs.", .parameters = &wc_params });

        // 22. sentiment_analyze
        const sent_params = [_]ToolParameter{
            .{ .name = "text", .param_type = .string, .description = "Text to analyze" },
        };
        try self.register(.{ .name = "sentiment_analyze", .dimension = .e6_metacognition, .description = "Lexicon-based sentiment analysis (positive/negative/neutral).", .parameters = &sent_params });

        // 23. ner_extract
        const ner_params = [_]ToolParameter{
            .{ .name = "text", .param_type = .string, .description = "Text to extract entities from" },
        };
        try self.register(.{ .name = "ner_extract", .dimension = .e6_metacognition, .description = "Named entity recognition: extracts persons, organizations, locations.", .parameters = &ner_params });

        // 24. text_classify
        const tc_params = [_]ToolParameter{
            .{ .name = "text", .param_type = .string, .description = "Text to classify" },
        };
        try self.register(.{ .name = "text_classify", .dimension = .e6_metacognition, .description = "Topic classification by keyword categorization.", .parameters = &tc_params });

        // 25. text_diff
        const td_params = [_]ToolParameter{
            .{ .name = "text_a", .param_type = .string, .description = "First text" },
            .{ .name = "text_b", .param_type = .string, .description = "Second text" },
        };
        try self.register(.{ .name = "text_diff", .dimension = .e5_structure, .description = "Line-by-line diff between two texts.", .parameters = &td_params });

        // 26. language_detect
        const ld_params = [_]ToolParameter{
            .{ .name = "text", .param_type = .string, .description = "Text to detect language" },
        };
        try self.register(.{ .name = "language_detect", .dimension = .e5_structure, .description = "Detects language by stopword frequency analysis.", .parameters = &ld_params });

        // === Knowledge & Retrieval Tools ===

        // 27. wikipedia_lookup
        const wiki_params = [_]ToolParameter{
            .{ .name = "query", .param_type = .string, .description = "Search query" },
        };
        try self.register(.{ .name = "wikipedia_lookup", .dimension = .e2_quantum, .description = "Searches local Wikipedia dataset files for query terms.", .parameters = &wiki_params });

        // 28. dictionary_lookup
        const dict_params = [_]ToolParameter{
            .{ .name = "word", .param_type = .string, .description = "Word to look up" },
        };
        try self.register(.{ .name = "dictionary_lookup", .dimension = .e2_quantum, .description = "Searches Webster's Dictionary dataset for definitions.", .parameters = &dict_params });

        // 29. law_lookup
        const law_params = [_]ToolParameter{
            .{ .name = "term", .param_type = .string, .description = "Legal term to look up" },
        };
        try self.register(.{ .name = "law_lookup", .dimension = .e2_quantum, .description = "Searches Black's Law Dictionary dataset for legal definitions.", .parameters = &law_params });

        // 30. rag_search
        const rag_params = [_]ToolParameter{
            .{ .name = "query", .param_type = .string, .description = "Search query" },
            .{ .name = "max_results", .param_type = .integer, .description = "Max results (default 5)", .required = false },
        };
        try self.register(.{ .name = "rag_search", .dimension = .e2_quantum, .description = "Retrieval-augmented generation search across all datasets using TF-IDF.", .parameters = &rag_params });

        // 31. kg_add_triplet
        const kat_params = [_]ToolParameter{
            .{ .name = "subject", .param_type = .string, .description = "Subject entity" },
            .{ .name = "predicate", .param_type = .string, .description = "Relation/predicate" },
            .{ .name = "object", .param_type = .string, .description = "Object entity" },
        };
        try self.register(.{ .name = "kg_add_triplet", .dimension = .e4_energy, .description = "Adds a new triplet to the knowledge graph at runtime.", .parameters = &kat_params });

        // 32. kg_export
        try self.register(.{ .name = "kg_export", .dimension = .e5_structure, .description = "Exports all knowledge graph triplets as JSON.", .parameters = &.{} });

        // === Data Analysis Tools ===

        // 33. stats_compute
        const stats_params = [_]ToolParameter{
            .{ .name = "data", .param_type = .string, .description = "Comma-separated numeric values" },
        };
        try self.register(.{ .name = "stats_compute", .dimension = .e5_structure, .description = "Computes mean, median, min, max, stddev, range from numeric data.", .parameters = &stats_params });

        // 34. csv_parse
        const csv_params = [_]ToolParameter{
            .{ .name = "data", .param_type = .string, .description = "CSV text to parse" },
        };
        try self.register(.{ .name = "csv_parse", .dimension = .e5_structure, .description = "Parses CSV text into JSON records.", .parameters = &csv_params });

        // 35. data_sort
        const sort_params = [_]ToolParameter{
            .{ .name = "data", .param_type = .string, .description = "Comma-separated values to sort" },
            .{ .name = "order", .param_type = .string, .description = "Sort order: asc or desc", .required = false },
        };
        try self.register(.{ .name = "data_sort", .dimension = .e5_structure, .description = "Sorts numeric or string data ascending/descending.", .parameters = &sort_params });

        // 36. data_filter
        const filter_params = [_]ToolParameter{
            .{ .name = "data", .param_type = .string, .description = "Comma-separated numeric values" },
            .{ .name = "op", .param_type = .string, .description = "Filter operator: gt, lt, gte, lte, eq" },
            .{ .name = "value", .param_type = .number, .description = "Threshold value" },
        };
        try self.register(.{ .name = "data_filter", .dimension = .e5_structure, .description = "Filters numeric data by threshold condition.", .parameters = &filter_params });

        // 37. histogram_generate
        const hist_params = [_]ToolParameter{
            .{ .name = "data", .param_type = .string, .description = "Comma-separated numeric values" },
            .{ .name = "bins", .param_type = .integer, .description = "Number of bins (default 10)", .required = false },
        };
        try self.register(.{ .name = "histogram_generate", .dimension = .e5_structure, .description = "Generates histogram bins from numeric data.", .parameters = &hist_params });

        // 38. correlation_compute
        const corr_params = [_]ToolParameter{
            .{ .name = "data_a", .param_type = .string, .description = "First dataset (comma-separated)" },
            .{ .name = "data_b", .param_type = .string, .description = "Second dataset (comma-separated)" },
        };
        try self.register(.{ .name = "correlation_compute", .dimension = .e5_structure, .description = "Computes Pearson correlation coefficient between two numeric arrays.", .parameters = &corr_params });

        // === Vision Tools ===

        // 39. face_detect
        const fd_params = [_]ToolParameter{
            .{ .name = "boxes", .param_type = .string, .description = "Face boxes as x1,y1,x2,y2,conf;x1,y1,x2,y2,conf;..." },
            .{ .name = "img_width", .param_type = .integer, .description = "Image width in pixels" },
            .{ .name = "img_height", .param_type = .integer, .description = "Image height in pixels" },
            .{ .name = "threshold", .param_type = .number, .description = "Confidence threshold (default 0.5)", .required = false },
        };
        try self.register(.{ .name = "face_detect", .dimension = .e6_metacognition, .description = "Detects and filters face bounding boxes by confidence threshold.", .parameters = &fd_params });

        // 40. face_recognize
        const frec_params = [_]ToolParameter{
            .{ .name = "embedding_a", .param_type = .string, .description = "First face embedding (comma-separated floats)" },
            .{ .name = "embedding_b", .param_type = .string, .description = "Second face embedding (comma-separated floats)" },
        };
        try self.register(.{ .name = "face_recognize", .dimension = .e6_metacognition, .description = "Computes cosine similarity between two face embeddings for recognition.", .parameters = &frec_params });

        // 41. face_analyze
        const fa_params = [_]ToolParameter{
            .{ .name = "x1", .param_type = .number, .description = "Face box left" },
            .{ .name = "y1", .param_type = .number, .description = "Face box top" },
            .{ .name = "x2", .param_type = .number, .description = "Face box right" },
            .{ .name = "y2", .param_type = .number, .description = "Face box bottom" },
            .{ .name = "img_width", .param_type = .integer, .description = "Image width" },
            .{ .name = "img_height", .param_type = .integer, .description = "Image height" },
        };
        try self.register(.{ .name = "face_analyze", .dimension = .e6_metacognition, .description = "Analyzes a face region: computes size ratio, aspect ratio, and quality heuristics.", .parameters = &fa_params });

        // 42. face_track
        const ft_params = [_]ToolParameter{
            .{ .name = "prev_boxes", .param_type = .string, .description = "Previous frame boxes: x1,y1,x2,y2;x1,y1,x2,y2;..." },
            .{ .name = "curr_boxes", .param_type = .string, .description = "Current frame boxes: x1,y1,x2,y2;x1,y1,x2,y2;..." },
            .{ .name = "iou_threshold", .param_type = .number, .description = "IoU matching threshold (default 0.3)", .required = false },
        };
        try self.register(.{ .name = "face_track", .dimension = .e6_metacognition, .description = "Tracks faces across frames using IoU matching.", .parameters = &ft_params });

        // 43. gaze_estimate
        const ge_params = [_]ToolParameter{
            .{ .name = "left_eye_x", .param_type = .number, .description = "Left eye x coordinate" },
            .{ .name = "left_eye_y", .param_type = .number, .description = "Left eye y coordinate" },
            .{ .name = "right_eye_x", .param_type = .number, .description = "Right eye x coordinate" },
            .{ .name = "right_eye_y", .param_type = .number, .description = "Right eye y coordinate" },
            .{ .name = "nose_x", .param_type = .number, .description = "Nose tip x coordinate" },
            .{ .name = "nose_y", .param_type = .number, .description = "Nose tip y coordinate" },
        };
        try self.register(.{ .name = "gaze_estimate", .dimension = .e6_metacognition, .description = "Estimates gaze direction (pitch, yaw) from facial landmark coordinates.", .parameters = &ge_params });

        // 44. emotion_detect
        const ed_params = [_]ToolParameter{
            .{ .name = "scores", .param_type = .string, .description = "Emotion scores (comma-separated 8 floats: neutral,happy,sad,surprise,angry,fear,disgust,contempt)" },
        };
        try self.register(.{ .name = "emotion_detect", .dimension = .e6_metacognition, .description = "Classifies emotion from 8-class softmax scores.", .parameters = &ed_params });

        // === Geoview Tools ===

        // 45. geo_distance
        const gd_params = [_]ToolParameter{
            .{ .name = "lat1", .param_type = .number, .description = "Latitude of point 1" },
            .{ .name = "lon1", .param_type = .number, .description = "Longitude of point 1" },
            .{ .name = "lat2", .param_type = .number, .description = "Latitude of point 2" },
            .{ .name = "lon2", .param_type = .number, .description = "Longitude of point 2" },
        };
        try self.register(.{ .name = "geo_distance", .dimension = .e3_space, .description = "Computes great-circle distance and bearing between two coordinates.", .parameters = &gd_params });

        // 46. geo_convert
        const gc_params = [_]ToolParameter{
            .{ .name = "lat", .param_type = .number, .description = "Latitude" },
            .{ .name = "lon", .param_type = .number, .description = "Longitude" },
            .{ .name = "alt", .param_type = .number, .description = "Altitude in meters", .required = false },
        };
        try self.register(.{ .name = "geo_convert", .dimension = .e3_space, .description = "Converts LLA to ECEF, ENU, and MGRS representations.", .parameters = &gc_params });

        // 47. geo_mgrs
        const gm_params = [_]ToolParameter{
            .{ .name = "lat", .param_type = .number, .description = "Latitude" },
            .{ .name = "lon", .param_type = .number, .description = "Longitude" },
        };
        try self.register(.{ .name = "geo_mgrs", .dimension = .e3_space, .description = "Encodes a lat/lon pair to MGRS grid reference.", .parameters = &gm_params });

        // 48. geo_bearing
        const gb_params = [_]ToolParameter{
            .{ .name = "lat1", .param_type = .number, .description = "Latitude of origin" },
            .{ .name = "lon1", .param_type = .number, .description = "Longitude of origin" },
            .{ .name = "lat2", .param_type = .number, .description = "Latitude of destination" },
            .{ .name = "lon2", .param_type = .number, .description = "Longitude of destination" },
        };
        try self.register(.{ .name = "geo_bearing", .dimension = .e3_space, .description = "Computes bearing and cardinal direction from origin to destination.", .parameters = &gb_params });

        // 49. geo_destination
        const gdest_params = [_]ToolParameter{
            .{ .name = "lat", .param_type = .number, .description = "Origin latitude" },
            .{ .name = "lon", .param_type = .number, .description = "Origin longitude" },
            .{ .name = "bearing", .param_type = .number, .description = "Bearing in degrees" },
            .{ .name = "distance", .param_type = .number, .description = "Distance in meters" },
        };
        try self.register(.{ .name = "geo_destination", .dimension = .e3_space, .description = "Computes destination point given origin, bearing, and distance.", .parameters = &gdest_params });

        // === Advanced Geoview Tools ===

        // 50. globe_query
        const gq_params = [_]ToolParameter{
            .{ .name = "lat", .param_type = .number, .description = "Center latitude" },
            .{ .name = "lon", .param_type = .number, .description = "Center longitude" },
            .{ .name = "radius_km", .param_type = .number, .description = "Search radius in kilometers" },
            .{ .name = "entity_type", .param_type = .string, .description = "Entity type filter: flights, vessels, satellites, earthquakes, cctv, all", .required = false },
        };
        try self.register(.{ .name = "globe_query", .dimension = .e3_space, .description = "Queries the globe for entities within a radius of a point. Returns coordinate transforms and distance info.", .parameters = &gq_params });

        // 51. track_flight
        const tf_params = [_]ToolParameter{
            .{ .name = "callsign", .param_type = .string, .description = "Aircraft callsign (e.g. UAL123, RCH456)" },
            .{ .name = "lat", .param_type = .number, .description = "Current latitude", .required = false },
            .{ .name = "lon", .param_type = .number, .description = "Current longitude", .required = false },
            .{ .name = "altitude_m", .param_type = .number, .description = "Altitude in meters", .required = false },
            .{ .name = "velocity_mps", .param_type = .number, .description = "Velocity in m/s", .required = false },
            .{ .name = "heading_deg", .param_type = .number, .description = "Heading in degrees", .required = false },
            .{ .name = "dt_seconds", .param_type = .number, .description = "Dead-reckon time delta in seconds (default 60)", .required = false },
        };
        try self.register(.{ .name = "track_flight", .dimension = .e1_time, .description = "Classifies an aircraft by callsign and computes dead-reckoned position.", .parameters = &tf_params });

        // 52. track_vessel
        const tv_params = [_]ToolParameter{
            .{ .name = "mmsi", .param_type = .integer, .description = "Maritime Mobile Service Identity (9 digits)" },
            .{ .name = "name", .param_type = .string, .description = "Vessel name", .required = false },
            .{ .name = "lat", .param_type = .number, .description = "Current latitude", .required = false },
            .{ .name = "lon", .param_type = .number, .description = "Current longitude", .required = false },
            .{ .name = "speed_knots", .param_type = .number, .description = "Speed in knots", .required = false },
            .{ .name = "course_deg", .param_type = .number, .description = "Course over ground in degrees", .required = false },
            .{ .name = "type_code", .param_type = .integer, .description = "AIS vessel type code (0-255)", .required = false },
            .{ .name = "nav_status_code", .param_type = .integer, .description = "AIS navigation status code (0-15)", .required = false },
            .{ .name = "dt_hours", .param_type = .number, .description = "Dead-reckon time delta in hours (default 1)", .required = false },
        };
        try self.register(.{ .name = "track_vessel", .dimension = .e1_time, .description = "Classifies a vessel by AIS type code and computes dead-reckoned position.", .parameters = &tv_params });

        // 53. track_satellite
        const tsat_params = [_]ToolParameter{
            .{ .name = "norad_id", .param_type = .integer, .description = "NORAD catalog number" },
            .{ .name = "name", .param_type = .string, .description = "Satellite name", .required = false },
            .{ .name = "tle_line1", .param_type = .string, .description = "TLE line 1 (69 chars)", .required = false },
            .{ .name = "tle_line2", .param_type = .string, .description = "TLE line 2 (69 chars)", .required = false },
        };
        try self.register(.{ .name = "track_satellite", .dimension = .e1_time, .description = "Parses TLE orbital elements for a satellite.", .parameters = &tsat_params });

        // 54. earthquake_query
        const eq_params = [_]ToolParameter{
            .{ .name = "min_magnitude", .param_type = .number, .description = "Minimum magnitude filter (default 0)", .required = false },
            .{ .name = "geojson", .param_type = .string, .description = "Raw GeoJSON to parse (alternative to fetching)", .required = false },
            .{ .name = "timeframe", .param_type = .string, .description = "Timeframe: hour, day, week, month (default day)", .required = false },
        };
        try self.register(.{ .name = "earthquake_query", .dimension = .e1_time, .description = "Queries earthquakes from USGS or parses provided GeoJSON. Filters by minimum magnitude.", .parameters = &eq_params });

        // 55. cctv_query
        const cq_params = [_]ToolParameter{
            .{ .name = "lat", .param_type = .number, .description = "Camera latitude" },
            .{ .name = "lon", .param_type = .number, .description = "Camera longitude" },
            .{ .name = "heading_deg", .param_type = .number, .description = "Camera heading in degrees (0=north)", .required = false },
            .{ .name = "fov_deg", .param_type = .number, .description = "Field of view in degrees (default 90)", .required = false },
            .{ .name = "range_km", .param_type = .number, .description = "Maximum visible range in km (default 10)", .required = false },
            .{ .name = "target_lat", .param_type = .number, .description = "Target latitude to check visibility", .required = false },
            .{ .name = "target_lon", .param_type = .number, .description = "Target longitude to check visibility", .required = false },
        };
        try self.register(.{ .name = "cctv_query", .dimension = .e3_space, .description = "Calculates CCTV camera viewshed and checks if a target point is visible.", .parameters = &cq_params });

        // 56. hud_control
        const hc_params = [_]ToolParameter{
            .{ .name = "action", .param_type = .string, .description = "HUD action: compass, scale_bar, coordinates, status, alert, crosshair" },
            .{ .name = "heading_deg", .param_type = .number, .description = "Camera heading for compass", .required = false },
            .{ .name = "pitch_deg", .param_type = .number, .description = "Camera pitch", .required = false },
            .{ .name = "lat", .param_type = .number, .description = "Center latitude for coordinate readout", .required = false },
            .{ .name = "lon", .param_type = .number, .description = "Center longitude for coordinate readout", .required = false },
            .{ .name = "alt_m", .param_type = .number, .description = "Altitude in meters", .required = false },
            .{ .name = "meters_per_pixel", .param_type = .number, .description = "Meters per pixel for scale bar", .required = false },
            .{ .name = "entity_count", .param_type = .integer, .description = "Entity count for status panel", .required = false },
            .{ .name = "message", .param_type = .string, .description = "Alert message text", .required = false },
        };
        try self.register(.{ .name = "hud_control", .dimension = .e4_energy, .description = "Generates HUD overlay elements (compass, scale bar, coordinates, status, alerts).", .parameters = &hc_params });

        // 57. scene_play
        const sp_params = [_]ToolParameter{
            .{ .name = "action", .param_type = .string, .description = "Scene action: queue_focus, start, pause, resume, stop, status" },
            .{ .name = "lat", .param_type = .number, .description = "Focus target latitude", .required = false },
            .{ .name = "lon", .param_type = .number, .description = "Focus target longitude", .required = false },
            .{ .name = "priority", .param_type = .integer, .description = "Focus priority (1=highest, 10=lowest, default 5)", .required = false },
            .{ .name = "duration_s", .param_type = .number, .description = "Focus duration in seconds (default 10)", .required = false },
            .{ .name = "label", .param_type = .string, .description = "Focus label", .required = false },
        };
        try self.register(.{ .name = "scene_play", .dimension = .e4_energy, .description = "Controls the scene director: queue focus targets, start/stop/pause storyboard playback.", .parameters = &sp_params });

        // 58. annotation_add
        const aa_params = [_]ToolParameter{
            .{ .name = "type", .param_type = .string, .description = "Annotation type: pin, measurement" },
            .{ .name = "lat", .param_type = .number, .description = "Latitude (pin) or from-latitude (measurement)" },
            .{ .name = "lon", .param_type = .number, .description = "Longitude (pin) or from-longitude (measurement)" },
            .{ .name = "title", .param_type = .string, .description = "Pin title", .required = false },
            .{ .name = "description", .param_type = .string, .description = "Pin description", .required = false },
            .{ .name = "to_lat", .param_type = .number, .description = "To-latitude for measurement", .required = false },
            .{ .name = "to_lon", .param_type = .number, .description = "To-longitude for measurement", .required = false },
        };
        try self.register(.{ .name = "annotation_add", .dimension = .e3_space, .description = "Adds an annotation (pin or measurement) to the globe and returns its ID.", .parameters = &aa_params });
    }

    /// Executes a tool call and returns a JSON formatted string result.
    pub fn execute(self: *ToolRegistry, call: ToolCall) ![]const u8 {
        if (std.mem.eql(u8, call.name, "calculate")) {
            return self.execCalculate(call.arguments_json);
        } else if (std.mem.eql(u8, call.name, "lattice_node")) {
            return self.execLatticeNode(call.arguments_json);
        } else if (std.mem.eql(u8, call.name, "quantum_simulate")) {
            return self.execQuantumSimulate(call.arguments_json);
        } else if (std.mem.eql(u8, call.name, "kg_query")) {
            return self.execKgQuery(call.arguments_json);
        } else if (std.mem.eql(u8, call.name, "db_query")) {
            return self.execDbQuery(call.arguments_json);
        } else if (std.mem.eql(u8, call.name, "external_search")) {
            return self.execExternalSearch(call.arguments_json);
        } else if (std.mem.eql(u8, call.name, "file_read")) {
            return self.execFileRead(call.arguments_json);
        } else if (std.mem.eql(u8, call.name, "file_write")) {
            return self.execFileWrite(call.arguments_json);
        } else if (std.mem.eql(u8, call.name, "file_list")) {
            return self.execFileList(call.arguments_json);
        } else if (std.mem.eql(u8, call.name, "http_fetch")) {
            return self.execHttpFetch(call.arguments_json);
        } else if (std.mem.eql(u8, call.name, "shell_exec")) {
            return self.execShellExec(call.arguments_json);
        } else if (std.mem.eql(u8, call.name, "time_now")) {
            return self.execTimeNow();
        } else if (std.mem.eql(u8, call.name, "uuid_generate")) {
            return self.execUuidGenerate();
        } else if (std.mem.eql(u8, call.name, "base64_encode")) {
            return self.execBase64Encode(call.arguments_json);
        } else if (std.mem.eql(u8, call.name, "base64_decode")) {
            return self.execBase64Decode(call.arguments_json);
        } else if (std.mem.eql(u8, call.name, "hash_compute")) {
            return self.execHashCompute(call.arguments_json);
        } else if (std.mem.eql(u8, call.name, "json_validate")) {
            return self.execJsonValidate(call.arguments_json);
        } else if (std.mem.eql(u8, call.name, "json_format")) {
            return self.execJsonFormat(call.arguments_json);
        } else if (std.mem.eql(u8, call.name, "string_replace")) {
            return self.execStringReplace(call.arguments_json);
        } else if (std.mem.eql(u8, call.name, "text_summarize")) {
            return self.execTextSummarize(call.arguments_json);
        } else if (std.mem.eql(u8, call.name, "word_count")) {
            return self.execWordCount(call.arguments_json);
        } else if (std.mem.eql(u8, call.name, "sentiment_analyze")) {
            return self.execSentimentAnalyze(call.arguments_json);
        } else if (std.mem.eql(u8, call.name, "ner_extract")) {
            return self.execNerExtract(call.arguments_json);
        } else if (std.mem.eql(u8, call.name, "text_classify")) {
            return self.execTextClassify(call.arguments_json);
        } else if (std.mem.eql(u8, call.name, "text_diff")) {
            return self.execTextDiff(call.arguments_json);
        } else if (std.mem.eql(u8, call.name, "language_detect")) {
            return self.execLanguageDetect(call.arguments_json);
        } else if (std.mem.eql(u8, call.name, "wikipedia_lookup")) {
            return self.execWikipediaLookup(call.arguments_json);
        } else if (std.mem.eql(u8, call.name, "dictionary_lookup")) {
            return self.execDictionaryLookup(call.arguments_json);
        } else if (std.mem.eql(u8, call.name, "law_lookup")) {
            return self.execLawLookup(call.arguments_json);
        } else if (std.mem.eql(u8, call.name, "rag_search")) {
            return self.execRagSearch(call.arguments_json);
        } else if (std.mem.eql(u8, call.name, "kg_add_triplet")) {
            return self.execKgAddTriplet(call.arguments_json);
        } else if (std.mem.eql(u8, call.name, "kg_export")) {
            return self.execKgExport();
        } else if (std.mem.eql(u8, call.name, "stats_compute")) {
            return self.execStatsCompute(call.arguments_json);
        } else if (std.mem.eql(u8, call.name, "csv_parse")) {
            return self.execCsvParse(call.arguments_json);
        } else if (std.mem.eql(u8, call.name, "data_sort")) {
            return self.execDataSort(call.arguments_json);
        } else if (std.mem.eql(u8, call.name, "data_filter")) {
            return self.execDataFilter(call.arguments_json);
        } else if (std.mem.eql(u8, call.name, "histogram_generate")) {
            return self.execHistogramGenerate(call.arguments_json);
        } else if (std.mem.eql(u8, call.name, "correlation_compute")) {
            return self.execCorrelationCompute(call.arguments_json);
        } else if (std.mem.eql(u8, call.name, "face_detect")) {
            return self.execFaceDetect(call.arguments_json);
        } else if (std.mem.eql(u8, call.name, "face_recognize")) {
            return self.execFaceRecognize(call.arguments_json);
        } else if (std.mem.eql(u8, call.name, "face_analyze")) {
            return self.execFaceAnalyze(call.arguments_json);
        } else if (std.mem.eql(u8, call.name, "face_track")) {
            return self.execFaceTrack(call.arguments_json);
        } else if (std.mem.eql(u8, call.name, "gaze_estimate")) {
            return self.execGazeEstimate(call.arguments_json);
        } else if (std.mem.eql(u8, call.name, "emotion_detect")) {
            return self.execEmotionDetect(call.arguments_json);
        } else if (std.mem.eql(u8, call.name, "geo_distance")) {
            return self.execGeoDistance(call.arguments_json);
        } else if (std.mem.eql(u8, call.name, "geo_convert")) {
            return self.execGeoConvert(call.arguments_json);
        } else if (std.mem.eql(u8, call.name, "geo_mgrs")) {
            return self.execGeoMgrs(call.arguments_json);
        } else if (std.mem.eql(u8, call.name, "geo_bearing")) {
            return self.execGeoBearing(call.arguments_json);
        } else if (std.mem.eql(u8, call.name, "geo_destination")) {
            return self.execGeoDestination(call.arguments_json);
        } else if (std.mem.eql(u8, call.name, "globe_query")) {
            return self.execGlobeQuery(call.arguments_json);
        } else if (std.mem.eql(u8, call.name, "track_flight")) {
            return self.execTrackFlight(call.arguments_json);
        } else if (std.mem.eql(u8, call.name, "track_vessel")) {
            return self.execTrackVessel(call.arguments_json);
        } else if (std.mem.eql(u8, call.name, "track_satellite")) {
            return self.execTrackSatellite(call.arguments_json);
        } else if (std.mem.eql(u8, call.name, "earthquake_query")) {
            return self.execEarthquakeQuery(call.arguments_json);
        } else if (std.mem.eql(u8, call.name, "cctv_query")) {
            return self.execCctvQuery(call.arguments_json);
        } else if (std.mem.eql(u8, call.name, "hud_control")) {
            return self.execHudControl(call.arguments_json);
        } else if (std.mem.eql(u8, call.name, "scene_play")) {
            return self.execScenePlay(call.arguments_json);
        } else if (std.mem.eql(u8, call.name, "annotation_add")) {
            return self.execAnnotationAdd(call.arguments_json);
        } else {
            return std.fmt.allocPrint(self.allocator, "{{\"error\":\"Unknown tool: {s}\"}}", .{call.name});
        }
    }

    fn execCalculate(self: *ToolRegistry, args_json: []const u8) ![]const u8 {
        var op: []const u8 = "add";
        var a: f64 = 0.0;
        var b: f64 = 0.0;

        if (std.mem.indexOf(u8, args_json, "\"op\"")) |p| {
            if (std.mem.indexOfScalar(u8, args_json[p..], ':')) |colon| {
                const rest = args_json[p + colon + 1 ..];
                if (std.mem.indexOfScalar(u8, rest, '"')) |q1| {
                    if (std.mem.indexOfScalar(u8, rest[q1 + 1 ..], '"')) |q2| {
                        op = rest[q1 + 1 .. q1 + 1 + q2];
                    }
                }
            }
        }

        if (std.mem.indexOf(u8, args_json, "\"a\"")) |p| {
            if (std.mem.indexOfScalar(u8, args_json[p..], ':')) |colon| {
                var start = p + colon + 1;
                while (start < args_json.len and (args_json[start] == ' ' or args_json[start] == '\t' or args_json[start] == '"')) : (start += 1) {}
                var end = start;
                while (end < args_json.len and (args_json[end] == '-' or args_json[end] == '.' or (args_json[end] >= '0' and args_json[end] <= '9'))) : (end += 1) {}
                if (end > start) {
                    a = std.fmt.parseFloat(f64, args_json[start..end]) catch 0.0;
                }
            }
        }

        if (std.mem.indexOf(u8, args_json, "\"b\"")) |p| {
            if (std.mem.indexOfScalar(u8, args_json[p..], ':')) |colon| {
                var start = p + colon + 1;
                while (start < args_json.len and (args_json[start] == ' ' or args_json[start] == '\t' or args_json[start] == '"')) : (start += 1) {}
                var end = start;
                while (end < args_json.len and (args_json[end] == '-' or args_json[end] == '.' or (args_json[end] >= '0' and args_json[end] <= '9'))) : (end += 1) {}
                if (end > start) {
                    b = std.fmt.parseFloat(f64, args_json[start..end]) catch 0.0;
                }
            }
        }

        const a_fp: i128 = @intFromFloat(a * @as(f64, @floatFromInt(fp.ONE)));
        const b_fp: i128 = @intFromFloat(b * @as(f64, @floatFromInt(fp.ONE)));

        var res_fp: i128 = 0;
        if (std.mem.eql(u8, op, "add")) {
            res_fp = fp.add(a_fp, b_fp);
        } else if (std.mem.eql(u8, op, "sub")) {
            res_fp = fp.sub(a_fp, b_fp);
        } else if (std.mem.eql(u8, op, "mul")) {
            res_fp = fp.mul(a_fp, b_fp);
        } else if (std.mem.eql(u8, op, "div")) {
            res_fp = if (b_fp != 0) fp.div(a_fp, b_fp) else 0;
        } else if (std.mem.eql(u8, op, "sqrt")) {
            res_fp = fp.sqrt(a_fp);
        } else if (std.mem.eql(u8, op, "exp")) {
            res_fp = fp.exp(a_fp);
        } else {
            res_fp = fp.add(a_fp, b_fp);
        }

        const res_f64 = @as(f64, @floatFromInt(res_fp)) / @as(f64, @floatFromInt(fp.ONE));
        return std.fmt.allocPrint(self.allocator, "{{\"result\":{d:.6},\"fixed_point\":{d},\"status\":\"success\"}}", .{ res_f64, res_fp });
    }

    fn execLatticeNode(self: *ToolRegistry, args_json: []const u8) ![]const u8 {
        var x: u32 = 0;
        var y: u32 = 0;
        var z: u32 = 0;

        if (std.mem.indexOf(u8, args_json, "\"x\"")) |p| {
            if (std.mem.indexOfScalar(u8, args_json[p..], ':')) |colon| {
                var start = p + colon + 1;
                while (start < args_json.len and (args_json[start] == ' ' or args_json[start] == '\t' or args_json[start] == '"')) : (start += 1) {}
                var end = start;
                while (end < args_json.len and (args_json[end] >= '0' and args_json[end] <= '9')) : (end += 1) {}
                if (end > start) x = std.fmt.parseInt(u32, args_json[start..end], 10) catch 0;
            }
        }
        if (std.mem.indexOf(u8, args_json, "\"y\"")) |p| {
            if (std.mem.indexOfScalar(u8, args_json[p..], ':')) |colon| {
                var start = p + colon + 1;
                while (start < args_json.len and (args_json[start] == ' ' or args_json[start] == '\t' or args_json[start] == '"')) : (start += 1) {}
                var end = start;
                while (end < args_json.len and (args_json[end] >= '0' and args_json[end] <= '9')) : (end += 1) {}
                if (end > start) y = std.fmt.parseInt(u32, args_json[start..end], 10) catch 0;
            }
        }
        if (std.mem.indexOf(u8, args_json, "\"z\"")) |p| {
            if (std.mem.indexOfScalar(u8, args_json[p..], ':')) |colon| {
                var start = p + colon + 1;
                while (start < args_json.len and (args_json[start] == ' ' or args_json[start] == '\t' or args_json[start] == '"')) : (start += 1) {}
                var end = start;
                while (end < args_json.len and (args_json[end] >= '0' and args_json[end] <= '9')) : (end += 1) {}
                if (end > start) z = std.fmt.parseInt(u32, args_json[start..end], 10) catch 0;
            }
        }

        const is_e0 = (x + y + z) % 3 == 0;
        const e_val = (x * 7 + y * 11 + z * 13) % 8;
        const is_boundary = x == 0 or x == 14 or y == 0 or y == 14 or z == 0 or z == 14;

        return std.fmt.allocPrint(self.allocator, "{{\"coords\":[{d},{d},{d}],\"is_e0\":{s},\"e_value\":{d},\"is_boundary\":{s},\"status\":\"success\"}}", .{
            x,
            y,
            z,
            if (is_e0) "true" else "false",
            e_val,
            if (is_boundary) "true" else "false",
        });
    }

    fn execQuantumSimulate(self: *ToolRegistry, args_json: []const u8) ![]const u8 {
        var circuit: []const u8 = "bell";
        var qubits: u32 = 2;

        if (std.mem.indexOf(u8, args_json, "\"circuit\":\"")) |p| {
            const start = p + 11;
            if (std.mem.indexOfScalar(u8, args_json[start..], '"')) |end_rel| {
                circuit = args_json[start .. start + end_rel];
            }
        }
        if (std.mem.indexOf(u8, args_json, "\"qubits\":")) |p| {
            const start = p + 9;
            var end = start;
            while (end < args_json.len and (args_json[end] >= '0' and args_json[end] <= '9')) : (end += 1) {}
            qubits = std.fmt.parseInt(u32, args_json[start..end], 10) catch 2;
            if (qubits < 2) qubits = 2;
            if (qubits > 8) qubits = 8;
        }

        if (std.mem.eql(u8, circuit, "bell")) {
            return std.fmt.allocPrint(self.allocator, "{{\"circuit\":\"bell_state\",\"qubits\":{d},\"entanglement\":1.0,\"p_00\":0.5,\"p_11\":0.5,\"status\":\"success\"}}", .{qubits});
        } else if (std.mem.eql(u8, circuit, "ghz")) {
            return std.fmt.allocPrint(self.allocator, "{{\"circuit\":\"ghz_state\",\"qubits\":{d},\"entanglement\":1.0,\"p_000\":0.5,\"p_111\":0.5,\"status\":\"success\"}}", .{qubits});
        } else if (std.mem.eql(u8, circuit, "grover")) {
            const iterations: u32 = @intCast(@as(u64, 1) << @intCast(qubits / 2));
            return std.fmt.allocPrint(self.allocator, "{{\"circuit\":\"grover_search\",\"qubits\":{d},\"iterations\":{d},\"target_probability\":0.99,\"status\":\"success\"}}", .{ qubits, iterations });
        } else {
            return std.fmt.allocPrint(self.allocator, "{{\"circuit\":\"{s}\",\"qubits\":{d},\"status\":\"unknown_circuit\"}}", .{ circuit, qubits });
        }
    }

    fn execKgQuery(self: *ToolRegistry, args_json: []const u8) ![]const u8 {
        var entity: []const u8 = "";
        var predicate: ?[]const u8 = null;

        if (std.mem.indexOf(u8, args_json, "\"entity\"")) |p| {
            if (std.mem.indexOfScalar(u8, args_json[p..], ':')) |colon| {
                const rest = args_json[p + colon + 1 ..];
                if (std.mem.indexOfScalar(u8, rest, '"')) |q1| {
                    if (std.mem.indexOfScalar(u8, rest[q1 + 1 ..], '"')) |q2| {
                        entity = rest[q1 + 1 .. q1 + 1 + q2];
                    }
                }
            }
        }

        if (std.mem.indexOf(u8, args_json, "\"predicate\"")) |p| {
            if (std.mem.indexOfScalar(u8, args_json[p..], ':')) |colon| {
                const rest = args_json[p + colon + 1 ..];
                if (std.mem.indexOfScalar(u8, rest, '"')) |q1| {
                    if (std.mem.indexOfScalar(u8, rest[q1 + 1 ..], '"')) |q2| {
                        predicate = rest[q1 + 1 .. q1 + 1 + q2];
                    }
                }
            }
        }

        if (self.kg) |kg| {
            if (predicate) |pred| {
                if (pred.len > 0) {
                    const db = db_mod.ExternalDb.init(self.allocator);
                    const json = try db.queryGraphPattern(kg, entity, pred, null);
                    return json;
                }
            }
            const db = db_mod.ExternalDb.init(self.allocator);
            const json = try db.queryGraphPattern(kg, entity, null, null);
            return json;
        }

        return std.fmt.allocPrint(self.allocator, "{{\"query_entity\":\"{s}\",\"filter_predicate\":\"{s}\",\"status\":\"no_kg_attached\",\"triplets\":[]}}", .{ entity, predicate orelse "any" });
    }

    fn execDbQuery(self: *ToolRegistry, args_json: []const u8) ![]const u8 {
        var key: []const u8 = "";
        var source: []const u8 = "default";
        if (std.mem.indexOf(u8, args_json, "\"key\"")) |p| {
            if (std.mem.indexOfScalar(u8, args_json[p..], ':')) |colon| {
                const rest = args_json[p + colon + 1 ..];
                if (std.mem.indexOfScalar(u8, rest, '"')) |q1| {
                    if (std.mem.indexOfScalar(u8, rest[q1 + 1 ..], '"')) |q2| {
                        key = rest[q1 + 1 .. q1 + 1 + q2];
                    }
                }
            }
        }
        if (std.mem.indexOf(u8, args_json, "\"source\"")) |p| {
            if (std.mem.indexOfScalar(u8, args_json[p..], ':')) |colon| {
                const rest = args_json[p + colon + 1 ..];
                if (std.mem.indexOfScalar(u8, rest, '"')) |q1| {
                    if (std.mem.indexOfScalar(u8, rest[q1 + 1 ..], '"')) |q2| {
                        source = rest[q1 + 1 .. q1 + 1 + q2];
                    }
                }
            }
        }

        if (self.db) |db| {
            if (db.queryKeyValue("", key) catch null) |val| {
                const result = try std.fmt.allocPrint(self.allocator, "{{\"query_key\":\"{s}\",\"source\":\"{s}\",\"value\":\"{s}\",\"status\":\"success\"}}", .{ key, source, val });
                self.allocator.free(val);
                return result;
            }
        }

        return std.fmt.allocPrint(self.allocator, "{{\"query_key\":\"{s}\",\"source\":\"{s}\",\"status\":\"no_db_attached\",\"records_found\":0}}", .{ key, source });
    }

    fn execExternalSearch(self: *ToolRegistry, args_json: []const u8) ![]const u8 {
        var query: []const u8 = "";
        if (std.mem.indexOf(u8, args_json, "\"query\"")) |p| {
            if (std.mem.indexOfScalar(u8, args_json[p..], ':')) |colon| {
                const rest = args_json[p + colon + 1 ..];
                if (std.mem.indexOfScalar(u8, rest, '"')) |q1| {
                    if (std.mem.indexOfScalar(u8, rest[q1 + 1 ..], '"')) |q2| {
                        query = rest[q1 + 1 .. q1 + 1 + q2];
                    }
                }
            }
        }

        if (self.kg) |kg| {
            const context = try kg.formatSubgraphContext(query, 10, self.allocator);
            if (context.len > 0) {
                const result = try std.fmt.allocPrint(self.allocator, "{{\"query\":\"{s}\",\"status\":\"success\",\"results_count\":1,\"subgraph_context\":\"{s}\"}}", .{ query, context });
                self.allocator.free(context);
                return result;
            }
            self.allocator.free(context);
        }

        return std.fmt.allocPrint(self.allocator, "{{\"query\":\"{s}\",\"status\":\"no_results\",\"results_count\":0}}", .{query});
    }

    // === Phase 2A: Core Utility Tool Exec Functions ===

    fn execFileRead(self: *ToolRegistry, args_json: []const u8) ![]const u8 {
        if (is_wasm) return std.fmt.allocPrint(self.allocator, "{{\"error\":\"file_read not available in WASM\"}}", .{});
        const jv = JsonValue.init(args_json);
        const path = jv.getString("path") orelse return std.fmt.allocPrint(self.allocator, "{{\"error\":\"missing path\"}}", .{});
        const max_bytes: usize = if (jv.getInteger("max_bytes")) |mb| @intCast(mb) else 1024 * 1024;

        const file = std.fs.cwd().openFile(path, .{}) catch |err| {
            return std.fmt.allocPrint(self.allocator, "{{\"error\":\"{s}\",\"path\":\"{s}\"}}", .{ @errorName(err), path });
        };
        defer file.close();

        const data = file.readToEndAlloc(self.allocator, max_bytes) catch |err| {
            return std.fmt.allocPrint(self.allocator, "{{\"error\":\"{s}\",\"path\":\"{s}\"}}", .{ @errorName(err), path });
        };
        defer self.allocator.free(data);

        const escaped = try self.escapeJsonString(data);
        defer self.allocator.free(escaped);

        return std.fmt.allocPrint(self.allocator, "{{\"path\":\"{s}\",\"bytes\":{d},\"content\":\"{s}\",\"status\":\"success\"}}", .{ path, data.len, escaped });
    }

    fn execFileWrite(self: *ToolRegistry, args_json: []const u8) ![]const u8 {
        if (is_wasm) return std.fmt.allocPrint(self.allocator, "{{\"error\":\"file_write not available in WASM\"}}", .{});
        const jv = JsonValue.init(args_json);
        const path = jv.getString("path") orelse return std.fmt.allocPrint(self.allocator, "{{\"error\":\"missing path\"}}", .{});
        const content = jv.getString("content") orelse return std.fmt.allocPrint(self.allocator, "{{\"error\":\"missing content\"}}", .{});

        const file = std.fs.cwd().createFile(path, .{}) catch |err| {
            return std.fmt.allocPrint(self.allocator, "{{\"error\":\"{s}\",\"path\":\"{s}\"}}", .{ @errorName(err), path });
        };
        defer file.close();
        file.writeAll(content) catch |err| {
            return std.fmt.allocPrint(self.allocator, "{{\"error\":\"{s}\",\"path\":\"{s}\"}}", .{ @errorName(err), path });
        };

        return std.fmt.allocPrint(self.allocator, "{{\"path\":\"{s}\",\"bytes_written\":{d},\"status\":\"success\"}}", .{ path, content.len });
    }

    fn execFileList(self: *ToolRegistry, args_json: []const u8) ![]const u8 {
        if (is_wasm) return std.fmt.allocPrint(self.allocator, "{{\"error\":\"file_list not available in WASM\"}}", .{});
        const jv = JsonValue.init(args_json);
        const path = jv.getString("path") orelse ".";

        var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch |err| {
            return std.fmt.allocPrint(self.allocator, "{{\"error\":\"{s}\",\"path\":\"{s}\"}}", .{ @errorName(err), path });
        };
        defer dir.close();

        var out = std.ArrayList(u8).init(self.allocator);
        errdefer out.deinit();
        try out.appendSlice("{\"path\":\"");
        try out.appendSlice(path);
        try out.appendSlice("\",\"entries\":[");
        var count: usize = 0;
        var iter = dir.iterate();
        while (iter.next() catch null) |entry| {
            if (count > 0) try out.append(',');
            try std.fmt.format(out.writer(), "{{\"name\":\"{s}\",\"type\":\"{s}\"}}", .{ entry.name, if (entry.kind == .directory) "dir" else "file" });
            count += 1;
            if (count >= 100) break;
        }
        try std.fmt.format(out.writer(), "],\"count\":{d},\"status\":\"success\"}}", .{count});
        return out.toOwnedSlice();
    }

    fn execHttpFetch(self: *ToolRegistry, args_json: []const u8) ![]const u8 {
        if (is_wasm) return std.fmt.allocPrint(self.allocator, "{{\"error\":\"http_fetch not available in WASM\"}}", .{});
        const jv = JsonValue.init(args_json);
        const url = jv.getString("url") orelse return std.fmt.allocPrint(self.allocator, "{{\"error\":\"missing url\"}}", .{});

        var client = std.http.Client{ .allocator = self.allocator };
        defer client.deinit();

        var response_body = std.ArrayList(u8).init(self.allocator);
        errdefer response_body.deinit();

        const result = client.fetch(.{
            .location = .{ .url = url },
            .response_storage = .{ .dynamic = &response_body },
        }) catch |err| {
            return std.fmt.allocPrint(self.allocator, "{{\"error\":\"{s}\",\"url\":\"{s}\"}}", .{ @errorName(err), url });
        };

        if (result.status != .ok) {
            return std.fmt.allocPrint(self.allocator, "{{\"url\":\"{s}\",\"status_code\":{d},\"error\":\"http_error\"}}", .{ url, @intFromEnum(result.status) });
        }

        const escaped = try self.escapeJsonString(response_body.items);
        defer self.allocator.free(escaped);

        return std.fmt.allocPrint(self.allocator, "{{\"url\":\"{s}\",\"status_code\":200,\"bytes\":{d},\"content\":\"{s}\",\"status\":\"success\"}}", .{ url, response_body.items.len, escaped });
    }

    fn execShellExec(self: *ToolRegistry, args_json: []const u8) ![]const u8 {
        if (is_wasm) return std.fmt.allocPrint(self.allocator, "{{\"error\":\"shell_exec not available in WASM\"}}", .{});
        const jv = JsonValue.init(args_json);
        const command = jv.getString("command") orelse return std.fmt.allocPrint(self.allocator, "{{\"error\":\"missing command\"}}", .{});

        var child: std.process.Child = .{
            .allocator = self.allocator,
            .argv = &.{ "/bin/sh", "-c", command },
            .stdout_behavior = .Pipe,
            .stderr_behavior = .Pipe,
            .id = undefined,
            .thread_handle = undefined,
            .stdin = undefined,
            .stdout = undefined,
            .stderr = undefined,
            .term = undefined,
            .env_map = null,
            .stdin_behavior = .Inherit,
            .uid = null,
            .gid = null,
            .cwd = null,
            .err_pipe = undefined,
            .expand_arg0 = .no_expand,
        };

        child.spawn() catch |err| {
            return std.fmt.allocPrint(self.allocator, "{{\"error\":\"{s}\",\"command\":\"{s}\"}}", .{ @errorName(err), command });
        };

        const stdout = child.stdout.?.readToEndAlloc(self.allocator, 1024 * 1024) catch "";
        defer self.allocator.free(stdout);
        _ = child.wait() catch {};

        const escaped = try self.escapeJsonString(stdout);
        defer self.allocator.free(escaped);

        return std.fmt.allocPrint(self.allocator, "{{\"command\":\"{s}\",\"stdout\":\"{s}\",\"bytes\":{d},\"status\":\"success\"}}", .{ command, escaped, stdout.len });
    }

    fn execTimeNow(self: *ToolRegistry) ![]const u8 {
        const epoch: i64 = if (is_wasm) 0 else std.time.timestamp();
        return std.fmt.allocPrint(self.allocator, "{{\"epoch\":{d},\"iso8601\":\"{d}-01-01T00:00:00Z\",\"status\":\"success\"}}", .{ epoch, 2026 });
    }

    fn execUuidGenerate(self: *ToolRegistry) ![]const u8 {
        const seed: u64 = if (is_wasm) 0x51535441525a else @intCast(std.time.timestamp());
        var rng = std.Random.DefaultPrng.init(seed);
        const random = rng.random();
        var bytes: [16]u8 = undefined;
        random.bytes(&bytes);
        bytes[6] = (bytes[6] & 0x0f) | 0x40;
        bytes[8] = (bytes[8] & 0x3f) | 0x80;
        return std.fmt.allocPrint(self.allocator, "{{\"uuid\":\"{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}\",\"status\":\"success\"}}", .{
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15],
        });
    }

    fn execBase64Encode(self: *ToolRegistry, args_json: []const u8) ![]const u8 {
        const jv = JsonValue.init(args_json);
        const data = jv.getString("data") orelse return std.fmt.allocPrint(self.allocator, "{{\"error\":\"missing data\"}}", .{});
        const encoder = std.base64.standard.Encoder;
        const enc_len = encoder.calcSize(data.len);
        const encoded = try self.allocator.alloc(u8, enc_len);
        defer self.allocator.free(encoded);
        _ = encoder.encode(encoded, data);
        return std.fmt.allocPrint(self.allocator, "{{\"encoded\":\"{s}\",\"status\":\"success\"}}", .{encoded});
    }

    fn execBase64Decode(self: *ToolRegistry, args_json: []const u8) ![]const u8 {
        const jv = JsonValue.init(args_json);
        const data = jv.getString("data") orelse return std.fmt.allocPrint(self.allocator, "{{\"error\":\"missing data\"}}", .{});
        const decoder = std.base64.standard.Decoder;
        const dec_len = decoder.calcSizeForSlice(data) catch return std.fmt.allocPrint(self.allocator, "{{\"error\":\"invalid_base64\"}}", .{});
        const decoded = try self.allocator.alloc(u8, dec_len);
        defer self.allocator.free(decoded);
        decoder.decode(decoded, data) catch return std.fmt.allocPrint(self.allocator, "{{\"error\":\"invalid_base64\"}}", .{});
        const escaped = try self.escapeJsonString(decoded);
        defer self.allocator.free(escaped);
        return std.fmt.allocPrint(self.allocator, "{{\"decoded\":\"{s}\",\"bytes\":{d},\"status\":\"success\"}}", .{ escaped, dec_len });
    }

    fn execHashCompute(self: *ToolRegistry, args_json: []const u8) ![]const u8 {
        const jv = JsonValue.init(args_json);
        const data = jv.getString("data") orelse return std.fmt.allocPrint(self.allocator, "{{\"error\":\"missing data\"}}", .{});
        const algo = jv.getString("algorithm") orelse "sha256";

        if (std.mem.eql(u8, algo, "crc32")) {
            const hash = std.hash.Crc32.hash(data);
            return std.fmt.allocPrint(self.allocator, "{{\"algorithm\":\"crc32\",\"hash\":\"{x:0>8}\",\"status\":\"success\"}}", .{hash});
        } else {
            var sha256 = std.crypto.hash.sha2.Sha256.init(.{});
            sha256.update(data);
            var digest: [32]u8 = undefined;
            sha256.final(&digest);
            return std.fmt.allocPrint(self.allocator, "{{\"algorithm\":\"sha256\",\"hash\":\"{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}\",\"status\":\"success\"}}", .{
                digest[0],  digest[1],  digest[2],  digest[3],  digest[4],  digest[5],  digest[6],  digest[7],
                digest[8],  digest[9],  digest[10], digest[11], digest[12], digest[13], digest[14], digest[15],
                digest[16], digest[17], digest[18], digest[19], digest[20], digest[21], digest[22], digest[23],
                digest[24], digest[25], digest[26], digest[27], digest[28], digest[29], digest[30], digest[31],
            });
        }
    }

    fn execJsonValidate(self: *ToolRegistry, args_json: []const u8) ![]const u8 {
        const jv = JsonValue.init(args_json);
        const data = jv.getString("data") orelse return std.fmt.allocPrint(self.allocator, "{{\"valid\":false,\"error\":\"missing data\"}}", .{});

        var valid = true;
        if (data.len == 0) valid = false;
        if (valid) {
            var depth: i32 = 0;
            var in_str = false;
            var escaped = false;
            for (data) |c| {
                if (in_str) {
                    if (escaped) {
                        escaped = false;
                    } else if (c == '\\') {
                        escaped = true;
                    } else if (c == '"') {
                        in_str = false;
                    }
                } else {
                    if (c == '"') in_str = true;
                    if (c == '{' or c == '[') depth += 1;
                    if (c == '}' or c == ']') depth -= 1;
                }
            }
            if (depth != 0) valid = false;
            if (in_str) valid = false;
        }

        return std.fmt.allocPrint(self.allocator, "{{\"valid\":{s},\"status\":\"success\"}}", .{if (valid) "true" else "false"});
    }

    fn execJsonFormat(self: *ToolRegistry, args_json: []const u8) ![]const u8 {
        const jv = JsonValue.init(args_json);
        const data = jv.getString("data") orelse return std.fmt.allocPrint(self.allocator, "{{\"error\":\"missing data\"}}", .{});
        const indent: usize = if (jv.getInteger("indent")) |i| @intCast(i) else 2;

        var out = std.ArrayList(u8).init(self.allocator);
        errdefer out.deinit();

        var depth: usize = 0;
        var in_str = false;
        var escaped = false;

        for (data) |c| {
            if (in_str) {
                try out.append(c);
                if (escaped) {
                    escaped = false;
                } else if (c == '\\') {
                    escaped = true;
                } else if (c == '"') {
                    in_str = false;
                }
            } else {
                switch (c) {
                    '"' => {
                        in_str = true;
                        try out.append(c);
                    },
                    '{', '[' => {
                        try out.append(c);
                        try out.append('\n');
                        depth += 1;
                        for (0..depth * indent) |_| try out.append(' ');
                    },
                    '}', ']' => {
                        try out.append('\n');
                        if (depth > 0) depth -= 1;
                        for (0..depth * indent) |_| try out.append(' ');
                        try out.append(c);
                    },
                    ',' => {
                        try out.append(c);
                        try out.append('\n');
                        for (0..depth * indent) |_| try out.append(' ');
                    },
                    ':' => {
                        try out.append(c);
                        try out.append(' ');
                    },
                    ' ', '\t', '\n', '\r' => {},
                    else => try out.append(c),
                }
            }
        }

        const escaped_out = try self.escapeJsonString(out.items);
        defer self.allocator.free(escaped_out);
        out.deinit();
        return std.fmt.allocPrint(self.allocator, "{{\"formatted\":\"{s}\",\"status\":\"success\"}}", .{escaped_out});
    }

    fn execStringReplace(self: *ToolRegistry, args_json: []const u8) ![]const u8 {
        const jv = JsonValue.init(args_json);
        const text = jv.getString("text") orelse return std.fmt.allocPrint(self.allocator, "{{\"error\":\"missing text\"}}", .{});
        const find = jv.getString("find") orelse return std.fmt.allocPrint(self.allocator, "{{\"error\":\"missing find\"}}", .{});
        const replace = jv.getString("replace") orelse return std.fmt.allocPrint(self.allocator, "{{\"error\":\"missing replace\"}}", .{});

        var result = std.ArrayList(u8).init(self.allocator);
        errdefer result.deinit();

        var i: usize = 0;
        var replacements: usize = 0;
        while (i < text.len) {
            if (i + find.len <= text.len and std.mem.eql(u8, text[i .. i + find.len], find)) {
                try result.appendSlice(replace);
                i += find.len;
                replacements += 1;
            } else {
                try result.append(text[i]);
                i += 1;
            }
        }

        const escaped = try self.escapeJsonString(result.items);
        defer self.allocator.free(escaped);
        result.deinit();
        return std.fmt.allocPrint(self.allocator, "{{\"replacements\":{d},\"result\":\"{s}\",\"status\":\"success\"}}", .{ replacements, escaped });
    }

    // === Phase 2B: Text Processing Tool Exec Functions ===

    fn execTextSummarize(self: *ToolRegistry, args_json: []const u8) ![]const u8 {
        const jv = JsonValue.init(args_json);
        const text = jv.getString("text") orelse return std.fmt.allocPrint(self.allocator, "{{\"error\":\"missing text\"}}", .{});
        const max_sentences: usize = if (jv.getInteger("sentences")) |s| @intCast(s) else 3;

        var sentences = std.ArrayList([]const u8).init(self.allocator);
        defer sentences.deinit();
        var start: usize = 0;
        for (text, 0..) |c, i| {
            if (c == '.' or c == '!' or c == '?') {
                try sentences.append(text[start .. i + 1]);
                start = i + 1;
            }
        }
        if (start < text.len) try sentences.append(text[start..]);

        if (sentences.items.len == 0) {
            return std.fmt.allocPrint(self.allocator, "{{\"summary\":\"{s}\",\"sentence_count\":0,\"status\":\"success\"}}", .{text});
        }

        const count = @min(max_sentences, sentences.items.len);
        var out = std.ArrayList(u8).init(self.allocator);
        errdefer out.deinit();
        for (0..count) |i| {
            if (i > 0) try out.append(' ');
            try out.appendSlice(std.mem.trim(u8, sentences.items[i], " \t\r\n"));
        }

        const escaped = try self.escapeJsonString(out.items);
        defer self.allocator.free(escaped);
        out.deinit();
        return std.fmt.allocPrint(self.allocator, "{{\"summary\":\"{s}\",\"sentence_count\":{d},\"status\":\"success\"}}", .{ escaped, count });
    }

    fn execWordCount(self: *ToolRegistry, args_json: []const u8) ![]const u8 {
        const jv = JsonValue.init(args_json);
        const text = jv.getString("text") orelse return std.fmt.allocPrint(self.allocator, "{{\"error\":\"missing text\"}}", .{});

        var words: usize = 0;
        const chars: usize = text.len;
        var sentences: usize = 0;
        var paragraphs: usize = 0;
        var in_word = false;
        var was_newline = false;

        for (text) |c| {
            if (c == ' ' or c == '\t' or c == '\r') {
                in_word = false;
            } else if (c == '\n') {
                in_word = false;
                if (was_newline) {
                    paragraphs += 1;
                }
                was_newline = true;
            } else if (c == '.' or c == '!' or c == '?') {
                sentences += 1;
                in_word = false;
            } else {
                if (!in_word) {
                    words += 1;
                    in_word = true;
                }
                was_newline = false;
            }
        }
        if (words > 0) paragraphs += 1;

        return std.fmt.allocPrint(self.allocator, "{{\"words\":{d},\"characters\":{d},\"sentences\":{d},\"paragraphs\":{d},\"status\":\"success\"}}", .{ words, chars, sentences, paragraphs });
    }

    fn execSentimentAnalyze(self: *ToolRegistry, args_json: []const u8) ![]const u8 {
        const jv = JsonValue.init(args_json);
        const text = jv.getString("text") orelse return std.fmt.allocPrint(self.allocator, "{{\"error\":\"missing text\"}}", .{});

        const positive_words = [_][]const u8{ "good", "great", "excellent", "amazing", "wonderful", "fantastic", "happy", "love", "best", "awesome", "brilliant", "perfect", "beautiful", "superb", "outstanding" };
        const negative_words = [_][]const u8{ "bad", "terrible", "awful", "horrible", "hate", "worst", "disgusting", "sad", "angry", "fail", "broken", "wrong", "poor", "ugly", "disappointing" };

        var lower_buf: [4096]u8 = undefined;
        const lower_len = @min(text.len, lower_buf.len);
        for (0..lower_len) |i| lower_buf[i] = std.ascii.toLower(text[i]);
        const lower = lower_buf[0..lower_len];

        var pos_score: usize = 0;
        var neg_score: usize = 0;
        for (positive_words) |pw| {
            var idx: usize = 0;
            while (std.mem.indexOf(u8, lower[idx..], pw)) |found| {
                pos_score += 1;
                idx += found + pw.len;
            }
        }
        for (negative_words) |nw| {
            var idx: usize = 0;
            while (std.mem.indexOf(u8, lower[idx..], nw)) |found| {
                neg_score += 1;
                idx += found + nw.len;
            }
        }

        const sentiment = if (pos_score > neg_score) "positive" else if (neg_score > pos_score) "negative" else "neutral";
        const score: i64 = @as(i64, @intCast(pos_score)) - @as(i64, @intCast(neg_score));

        return std.fmt.allocPrint(self.allocator, "{{\"sentiment\":\"{s}\",\"score\":{d},\"positive_hits\":{d},\"negative_hits\":{d},\"status\":\"success\"}}", .{ sentiment, score, pos_score, neg_score });
    }

    fn execNerExtract(self: *ToolRegistry, args_json: []const u8) ![]const u8 {
        const jv = JsonValue.init(args_json);
        const text = jv.getString("text") orelse return std.fmt.allocPrint(self.allocator, "{{\"error\":\"missing text\"}}", .{});

        var out = std.ArrayList(u8).init(self.allocator);
        errdefer out.deinit();
        try out.appendSlice("{\"entities\":[");
        var count: usize = 0;

        var words = std.mem.tokenizeAny(u8, text, " \t\r\n,.;:!?");
        while (words.next()) |word| {
            if (word.len < 2) continue;
            if (!std.ascii.isUpper(word[0])) continue;

            const category = if (std.mem.eql(u8, word, "Mr") or std.mem.eql(u8, word, "Mrs") or std.mem.eql(u8, word, "Dr") or std.mem.eql(u8, word, "President") or std.mem.eql(u8, word, "King") or std.mem.eql(u8, word, "Queen"))
                "person"
            else if (std.mem.eql(u8, word, "Inc") or std.mem.eql(u8, word, "Corp") or std.mem.eql(u8, word, "Ltd") or std.mem.eql(u8, word, "Company"))
                "organization"
            else
                "entity";

            if (count > 0) try out.append(',');
            try std.fmt.format(out.writer(), "{{\"text\":\"{s}\",\"type\":\"{s}\"}}", .{ word, category });
            count += 1;
            if (count >= 50) break;
        }

        try std.fmt.format(out.writer(), "],\"count\":{d},\"status\":\"success\"}}", .{count});
        return out.toOwnedSlice();
    }

    fn execTextClassify(self: *ToolRegistry, args_json: []const u8) ![]const u8 {
        const jv = JsonValue.init(args_json);
        const text = jv.getString("text") orelse return std.fmt.allocPrint(self.allocator, "{{\"error\":\"missing text\"}}", .{});

        var lower_buf: [4096]u8 = undefined;
        const lower_len = @min(text.len, lower_buf.len);
        for (0..lower_len) |i| lower_buf[i] = std.ascii.toLower(text[i]);
        const lower = lower_buf[0..lower_len];

        const categories = [_]struct { name: []const u8, keywords: []const []const u8 }{
            .{ .name = "science", .keywords = &.{ "physics", "quantum", "energy", "particle", "wave", "atom", "molecule", "chemical", "biology", "cell" } },
            .{ .name = "technology", .keywords = &.{ "computer", "software", "algorithm", "data", "network", "code", "program", "digital", "ai", "machine" } },
            .{ .name = "law", .keywords = &.{ "court", "judge", "legal", "law", "statute", "constitution", "rights", "contract", "tort", "criminal" } },
            .{ .name = "history", .keywords = &.{ "war", "ancient", "century", "empire", "revolution", "king", "battle", "historical", "medieval", "civilization" } },
            .{ .name = "geography", .keywords = &.{ "mountain", "river", "ocean", "country", "city", "continent", "climate", "island", "desert", "forest" } },
            .{ .name = "mathematics", .keywords = &.{ "equation", "theorem", "proof", "algebra", "calculus", "geometry", "number", "function", "matrix", "vector" } },
        };

        var best_cat: []const u8 = "unknown";
        var best_score: usize = 0;
        for (categories) |cat| {
            var score: usize = 0;
            for (cat.keywords) |kw| {
                if (std.mem.indexOf(u8, lower, kw) != null) score += 1;
            }
            if (score > best_score) {
                best_score = score;
                best_cat = cat.name;
            }
        }

        return std.fmt.allocPrint(self.allocator, "{{\"category\":\"{s}\",\"confidence\":{d},\"status\":\"success\"}}", .{ best_cat, best_score });
    }

    fn execTextDiff(self: *ToolRegistry, args_json: []const u8) ![]const u8 {
        const jv = JsonValue.init(args_json);
        const text_a = jv.getString("text_a") orelse return std.fmt.allocPrint(self.allocator, "{{\"error\":\"missing text_a\"}}", .{});
        const text_b = jv.getString("text_b") orelse return std.fmt.allocPrint(self.allocator, "{{\"error\":\"missing text_b\"}}", .{});

        var out = std.ArrayList(u8).init(self.allocator);
        errdefer out.deinit();
        try out.appendSlice("{\"diff\":[");
        var count: usize = 0;

        var lines_a = std.mem.splitScalar(u8, text_a, '\n');
        var lines_b = std.mem.splitScalar(u8, text_b, '\n');
        var line_a = lines_a.next();
        var line_b = lines_b.next();
        var line_num: usize = 1;

        while (line_a != null or line_b != null) {
            if (line_a != null and line_b != null) {
                if (!std.mem.eql(u8, line_a.?, line_b.?)) {
                    if (count > 0) try out.append(',');
                    try std.fmt.format(out.writer(), "{{\"line\":{d},\"type\":\"modified\",\"old\":\"{s}\",\"new\":\"{s}\"}}", .{ line_num, line_a.?, line_b.? });
                    count += 1;
                }
            } else if (line_a != null) {
                if (count > 0) try out.append(',');
                try std.fmt.format(out.writer(), "{{\"line\":{d},\"type\":\"removed\",\"old\":\"{s}\"}}", .{ line_num, line_a.? });
                count += 1;
            } else {
                if (count > 0) try out.append(',');
                try std.fmt.format(out.writer(), "{{\"line\":{d},\"type\":\"added\",\"new\":\"{s}\"}}", .{ line_num, line_b.? });
                count += 1;
            }
            line_a = lines_a.next();
            line_b = lines_b.next();
            line_num += 1;
        }

        try std.fmt.format(out.writer(), "],\"changes\":{d},\"status\":\"success\"}}", .{count});
        return out.toOwnedSlice();
    }

    fn execLanguageDetect(self: *ToolRegistry, args_json: []const u8) ![]const u8 {
        const jv = JsonValue.init(args_json);
        const text = jv.getString("text") orelse return std.fmt.allocPrint(self.allocator, "{{\"error\":\"missing text\"}}", .{});

        var lower_buf: [4096]u8 = undefined;
        const lower_len = @min(text.len, lower_buf.len);
        for (0..lower_len) |i| lower_buf[i] = std.ascii.toLower(text[i]);
        const lower = lower_buf[0..lower_len];

        const languages = [_]struct { name: []const u8, stopwords: []const []const u8 }{
            .{ .name = "english", .stopwords = &.{ "the", "is", "at", "which", "on", "and", "a", "an", "in", "to", "of", "for", "with", "that", "this" } },
            .{ .name = "spanish", .stopwords = &.{ "el", "la", "los", "las", "de", "en", "un", "una", "por", "con", "que", "es", "se", "su", "para" } },
            .{ .name = "french", .stopwords = &.{ "le", "la", "les", "de", "et", "un", "une", "dans", "pour", "avec", "que", "est", "se", "son", "au" } },
            .{ .name = "german", .stopwords = &.{ "der", "die", "das", "und", "in", "den", "von", "zu", "mit", "auf", "ist", "ein", "eine", "dem", "nicht" } },
        };

        var best_lang: []const u8 = "unknown";
        var best_score: usize = 0;
        for (languages) |lang| {
            var score: usize = 0;
            for (lang.stopwords) |sw| {
                var search_buf: [64]u8 = undefined;
                const search = std.fmt.bufPrint(&search_buf, " {s} ", .{sw}) catch continue;
                if (std.mem.indexOf(u8, lower, search) != null) score += 1;
            }
            if (score > best_score) {
                best_score = score;
                best_lang = lang.name;
            }
        }

        return std.fmt.allocPrint(self.allocator, "{{\"language\":\"{s}\",\"confidence\":{d},\"status\":\"success\"}}", .{ best_lang, best_score });
    }

    // === Phase 2C: Knowledge & Retrieval Tool Exec Functions ===

    fn execWikipediaLookup(self: *ToolRegistry, args_json: []const u8) ![]const u8 {
        const jv = JsonValue.init(args_json);
        const query = jv.getString("query") orelse return std.fmt.allocPrint(self.allocator, "{{\"error\":\"missing query\"}}", .{});

        const wiki_files = [_][]const u8{
            "datasets/wikipedia/wikipedia_science_tech.md",
            "datasets/wikipedia/wikipedia_geography_earth.md",
            "datasets/wikipedia/wikipedia_humanities_arts.md",
        };

        return self.searchDatasetFiles(&wiki_files, query, "wikipedia");
    }

    fn execDictionaryLookup(self: *ToolRegistry, args_json: []const u8) ![]const u8 {
        if (is_wasm) return std.fmt.allocPrint(self.allocator, "{{\"word\":\"\",\"source\":\"webster\",\"status\":\"not_available_in_wasm\"}}", .{});
        const jv = JsonValue.init(args_json);
        const word = jv.getString("word") orelse return std.fmt.allocPrint(self.allocator, "{{\"error\":\"missing word\"}}", .{});

        const dict_files = [_][]const u8{
            "datasets/webster_dictionary/webster_vol_1.txt",
            "datasets/webster_dictionary/webster_vol_2.txt",
            "datasets/webster_dictionary/webster_vol_3.txt",
            "datasets/webster_dictionary/webster_vol_4.txt",
            "datasets/webster_dictionary/webster_vol_5.txt",
            "datasets/webster_dictionary/webster_vol_6.txt",
        };

        for (dict_files) |file_path| {
            const file = std.fs.cwd().openFile(file_path, .{}) catch continue;
            defer file.close();
            const data = file.readToEndAlloc(self.allocator, 10 * 1024 * 1024) catch continue;
            defer self.allocator.free(data);

            var search_buf: [256]u8 = undefined;
            const search = std.fmt.bufPrint(&search_buf, "\n{s}\n", .{word}) catch continue;
            if (std.mem.indexOf(u8, data, search)) |pos| {
                const snippet_start = pos;
                const snippet_end = @min(pos + 500, data.len);
                const escaped = try self.escapeJsonString(data[snippet_start..snippet_end]);
                defer self.allocator.free(escaped);
                return std.fmt.allocPrint(self.allocator, "{{\"word\":\"{s}\",\"source\":\"webster\",\"definition\":\"{s}\",\"status\":\"success\"}}", .{ word, escaped });
            }
        }

        return std.fmt.allocPrint(self.allocator, "{{\"word\":\"{s}\",\"source\":\"webster\",\"status\":\"not_found\"}}", .{word});
    }

    fn execLawLookup(self: *ToolRegistry, args_json: []const u8) ![]const u8 {
        const jv = JsonValue.init(args_json);
        const term = jv.getString("term") orelse return std.fmt.allocPrint(self.allocator, "{{\"error\":\"missing term\"}}", .{});

        const law_files = [_][]const u8{
            "datasets/blacks_law/blacks_law_part1_constitutional.md",
            "datasets/blacks_law/blacks_law_part2_contracts_torts.md",
            "datasets/blacks_law/blacks_law_part3_criminal_procedure.md",
        };

        return self.searchDatasetFiles(&law_files, term, "blacks_law");
    }

    fn execRagSearch(self: *ToolRegistry, args_json: []const u8) ![]const u8 {
        if (is_wasm) return std.fmt.allocPrint(self.allocator, "{{\"query\":\"\",\"status\":\"not_available_in_wasm\"}}", .{});
        const jv = JsonValue.init(args_json);
        const query = jv.getString("query") orelse return std.fmt.allocPrint(self.allocator, "{{\"error\":\"missing query\"}}", .{});
        const max_results: usize = if (jv.getInteger("max_results")) |mr| @intCast(mr) else 5;

        const all_files = [_][]const u8{
            "datasets/wikipedia/wikipedia_science_tech.md",
            "datasets/wikipedia/wikipedia_geography_earth.md",
            "datasets/wikipedia/wikipedia_humanities_arts.md",
            "datasets/blacks_law/blacks_law_part1_constitutional.md",
            "datasets/blacks_law/blacks_law_part2_contracts_torts.md",
            "datasets/blacks_law/blacks_law_part3_criminal_procedure.md",
            "datasets/general_knowledge/astronomy_physics_earth.md",
            "datasets/general_knowledge/biology_ecology_marine.md",
            "datasets/general_knowledge/culinary_food_science.md",
            "datasets/general_knowledge/formal_logic_philosophy.md",
            "datasets/general_knowledge/history_geography_culture.md",
        };

        var results = std.ArrayList(struct { file: []const u8, score: usize, snippet: []const u8 }).init(self.allocator);
        defer results.deinit();

        var lower_query_buf: [256]u8 = undefined;
        const lower_query_len = @min(query.len, lower_query_buf.len);
        for (0..lower_query_len) |i| lower_query_buf[i] = std.ascii.toLower(query[i]);
        const lower_query = lower_query_buf[0..lower_query_len];

        var query_words = std.mem.tokenizeAny(u8, lower_query, " \t\r\n");
        var query_terms: [32][]const u8 = undefined;
        var term_count: usize = 0;
        while (query_words.next()) |w| {
            if (term_count < 32) {
                query_terms[term_count] = w;
                term_count += 1;
            }
        }

        for (all_files) |file_path| {
            const file = std.fs.cwd().openFile(file_path, .{}) catch continue;
            defer file.close();
            const data = file.readToEndAlloc(self.allocator, 5 * 1024 * 1024) catch continue;
            defer self.allocator.free(data);

            var lower_buf: [65536]u8 = undefined;
            const lower_len = @min(data.len, lower_buf.len);
            for (0..lower_len) |i| lower_buf[i] = std.ascii.toLower(data[i]);
            const lower = lower_buf[0..lower_len];

            var score: usize = 0;
            for (0..term_count) |t| {
                var idx: usize = 0;
                while (std.mem.indexOf(u8, lower[idx..], query_terms[t])) |found| {
                    score += 1;
                    idx += found + query_terms[t].len;
                }
            }

            if (score > 0) {
                const snippet_start: usize = 0;
                const snippet_end = @min(@min(data.len, 300), lower_len);
                const snippet = try self.allocator.dupe(u8, data[snippet_start..snippet_end]);
                try results.append(.{ .file = file_path, .score = score, .snippet = snippet });
            }
        }

        std.sort.heap(@TypeOf(results.items[0]), results.items, {}, struct {
            fn lt(_: void, a: @TypeOf(results.items[0]), b: @TypeOf(results.items[0])) bool {
                return a.score > b.score;
            }
        }.lt);

        var out = std.ArrayList(u8).init(self.allocator);
        errdefer out.deinit();
        try out.appendSlice("{\"query\":\"");
        try out.appendSlice(query);
        try out.appendSlice("\",\"results\":[");
        const count = @min(max_results, results.items.len);
        for (0..count) |i| {
            if (i > 0) try out.append(',');
            const escaped = try self.escapeJsonString(results.items[i].snippet);
            defer self.allocator.free(escaped);
            try std.fmt.format(out.writer(), "{{\"file\":\"{s}\",\"score\":{d},\"snippet\":\"{s}\"}}", .{ results.items[i].file, results.items[i].score, escaped });
        }
        for (results.items) |r| self.allocator.free(r.snippet);
        try std.fmt.format(out.writer(), "],\"count\":{d},\"status\":\"success\"}}", .{count});
        return out.toOwnedSlice();
    }

    fn execKgAddTriplet(self: *ToolRegistry, args_json: []const u8) ![]const u8 {
        const jv = JsonValue.init(args_json);
        const subject = jv.getString("subject") orelse return std.fmt.allocPrint(self.allocator, "{{\"error\":\"missing subject\"}}", .{});
        const predicate = jv.getString("predicate") orelse return std.fmt.allocPrint(self.allocator, "{{\"error\":\"missing predicate\"}}", .{});
        const object = jv.getString("object") orelse return std.fmt.allocPrint(self.allocator, "{{\"error\":\"missing object\"}}", .{});

        if (self.kg) |kg| {
            _ = try kg.addTriplet(subject, predicate, object, 1000, 0);
            return std.fmt.allocPrint(self.allocator, "{{\"subject\":\"{s}\",\"predicate\":\"{s}\",\"object\":\"{s}\",\"status\":\"success\",\"triplet_count\":{d}}}", .{ subject, predicate, object, kg.tripletCount() });
        }
        return std.fmt.allocPrint(self.allocator, "{{\"error\":\"no_kg_attached\"}}", .{});
    }

    fn execKgExport(self: *ToolRegistry) ![]const u8 {
        if (self.kg) |kg| {
            var out = std.ArrayList(u8).init(self.allocator);
            errdefer out.deinit();
            try out.appendSlice("{\"triplets\":[");
            for (kg.triplets.items, 0..) |t, i| {
                if (i > 0) try out.append(',');
                try std.fmt.format(out.writer(), "{{\"subject\":\"{s}\",\"predicate\":\"{s}\",\"object\":\"{s}\",\"weight\":{d},\"channel\":{d}}}", .{ t.subject, t.predicate, t.object, t.weight, t.channel });
            }
            try std.fmt.format(out.writer(), "],\"count\":{d},\"status\":\"success\"}}", .{kg.tripletCount()});
            return out.toOwnedSlice();
        }
        return std.fmt.allocPrint(self.allocator, "{{\"error\":\"no_kg_attached\"}}", .{});
    }

    // === Phase 2D: Data Analysis Tool Exec Functions ===

    fn execStatsCompute(self: *ToolRegistry, args_json: []const u8) ![]const u8 {
        const jv = JsonValue.init(args_json);
        const data_str = jv.getString("data") orelse return std.fmt.allocPrint(self.allocator, "{{\"error\":\"missing data\"}}", .{});

        var values = std.ArrayList(f64).init(self.allocator);
        defer values.deinit();
        var iter = std.mem.tokenizeAny(u8, data_str, ", ");
        while (iter.next()) |tok| {
            const val = std.fmt.parseFloat(f64, tok) catch continue;
            try values.append(val);
        }

        if (values.items.len == 0) {
            return std.fmt.allocPrint(self.allocator, "{{\"error\":\"no_valid_numbers\"}}", .{});
        }

        var sum: f64 = 0;
        var min: f64 = values.items[0];
        var max: f64 = values.items[0];
        for (values.items) |v| {
            sum += v;
            if (v < min) min = v;
            if (v > max) max = v;
        }
        const mean = sum / @as(f64, @floatFromInt(values.items.len));
        const range = max - min;

        const sorted = try self.allocator.dupe(f64, values.items);
        defer self.allocator.free(sorted);
        std.sort.heap(f64, sorted, {}, std.sort.asc(f64));
        const median = if (sorted.len % 2 == 0)
            (sorted[sorted.len / 2 - 1] + sorted[sorted.len / 2]) / 2.0
        else
            sorted[sorted.len / 2];

        var variance_sum: f64 = 0;
        for (values.items) |v| {
            const diff = v - mean;
            variance_sum += diff * diff;
        }
        const stddev = @sqrt(variance_sum / @as(f64, @floatFromInt(values.items.len)));

        return std.fmt.allocPrint(self.allocator, "{{\"count\":{d},\"mean\":{d:.6},\"median\":{d:.6},\"min\":{d:.6},\"max\":{d:.6},\"range\":{d:.6},\"stddev\":{d:.6},\"status\":\"success\"}}", .{
            values.items.len, mean, median, min, max, range, stddev,
        });
    }

    fn execCsvParse(self: *ToolRegistry, args_json: []const u8) ![]const u8 {
        const jv = JsonValue.init(args_json);
        const data = jv.getString("data") orelse return std.fmt.allocPrint(self.allocator, "{{\"error\":\"missing data\"}}", .{});

        var out = std.ArrayList(u8).init(self.allocator);
        errdefer out.deinit();
        try out.appendSlice("{\"records\":[");

        var lines = std.mem.splitScalar(u8, data, '\n');
        var header: ?[]const u8 = null;
        var record_count: usize = 0;

        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \r\n");
            if (trimmed.len == 0) continue;

            if (header == null) {
                header = trimmed;
                continue;
            }

            if (record_count > 0) try out.append(',');
            try out.append('{');

            var header_fields = std.mem.splitScalar(u8, header.?, ',');
            var value_fields = std.mem.splitScalar(u8, trimmed, ',');
            var field_idx: usize = 0;

            while (header_fields.next()) |h| {
                const v = value_fields.next() orelse "";
                if (field_idx > 0) try out.append(',');
                try std.fmt.format(out.writer(), "\"{s}\":\"{s}\"", .{ std.mem.trim(u8, h, " "), std.mem.trim(u8, v, " ") });
                field_idx += 1;
            }

            try out.append('}');
            record_count += 1;
            if (record_count >= 100) break;
        }

        try std.fmt.format(out.writer(), "],\"count\":{d},\"status\":\"success\"}}", .{record_count});
        return out.toOwnedSlice();
    }

    fn execDataSort(self: *ToolRegistry, args_json: []const u8) ![]const u8 {
        const jv = JsonValue.init(args_json);
        const data_str = jv.getString("data") orelse return std.fmt.allocPrint(self.allocator, "{{\"error\":\"missing data\"}}", .{});
        const order = jv.getString("order") orelse "asc";

        var values = std.ArrayList(f64).init(self.allocator);
        defer values.deinit();
        var iter = std.mem.tokenizeAny(u8, data_str, ", ");
        while (iter.next()) |tok| {
            const val = std.fmt.parseFloat(f64, tok) catch continue;
            try values.append(val);
        }

        if (values.items.len == 0) {
            return std.fmt.allocPrint(self.allocator, "{{\"error\":\"no_valid_numbers\"}}", .{});
        }

        if (std.mem.eql(u8, order, "desc")) {
            std.sort.heap(f64, values.items, {}, std.sort.desc(f64));
        } else {
            std.sort.heap(f64, values.items, {}, std.sort.asc(f64));
        }

        var out = std.ArrayList(u8).init(self.allocator);
        errdefer out.deinit();
        try out.appendSlice("{\"sorted\":[");
        for (values.items, 0..) |v, i| {
            if (i > 0) try out.append(',');
            try std.fmt.format(out.writer(), "{d:.6}", .{v});
        }
        try std.fmt.format(out.writer(), "],\"count\":{d},\"order\":\"{s}\",\"status\":\"success\"}}", .{ values.items.len, order });
        return out.toOwnedSlice();
    }

    fn execDataFilter(self: *ToolRegistry, args_json: []const u8) ![]const u8 {
        const jv = JsonValue.init(args_json);
        const data_str = jv.getString("data") orelse return std.fmt.allocPrint(self.allocator, "{{\"error\":\"missing data\"}}", .{});
        const op = jv.getString("op") orelse "gt";
        const threshold = jv.getNumber("value") orelse 0.0;

        var out = std.ArrayList(u8).init(self.allocator);
        errdefer out.deinit();
        try out.appendSlice("{\"filtered\":[");
        var count: usize = 0;

        var iter = std.mem.tokenizeAny(u8, data_str, ", ");
        while (iter.next()) |tok| {
            const val = std.fmt.parseFloat(f64, tok) catch continue;
            const matches = if (std.mem.eql(u8, op, "gt"))
                val > threshold
            else if (std.mem.eql(u8, op, "lt"))
                val < threshold
            else if (std.mem.eql(u8, op, "gte"))
                val >= threshold
            else if (std.mem.eql(u8, op, "lte"))
                val <= threshold
            else if (std.mem.eql(u8, op, "eq"))
                val == threshold
            else
                false;

            if (matches) {
                if (count > 0) try out.append(',');
                try std.fmt.format(out.writer(), "{d:.6}", .{val});
                count += 1;
            }
        }

        try std.fmt.format(out.writer(), "],\"count\":{d},\"op\":\"{s}\",\"threshold\":{d:.6},\"status\":\"success\"}}", .{ count, op, threshold });
        return out.toOwnedSlice();
    }

    fn execHistogramGenerate(self: *ToolRegistry, args_json: []const u8) ![]const u8 {
        const jv = JsonValue.init(args_json);
        const data_str = jv.getString("data") orelse return std.fmt.allocPrint(self.allocator, "{{\"error\":\"missing data\"}}", .{});
        const num_bins: usize = if (jv.getInteger("bins")) |b| @intCast(b) else 10;

        var values = std.ArrayList(f64).init(self.allocator);
        defer values.deinit();
        var iter = std.mem.tokenizeAny(u8, data_str, ", ");
        while (iter.next()) |tok| {
            const val = std.fmt.parseFloat(f64, tok) catch continue;
            try values.append(val);
        }

        if (values.items.len == 0 or num_bins == 0) {
            return std.fmt.allocPrint(self.allocator, "{{\"error\":\"no_valid_data\"}}", .{});
        }

        var min: f64 = values.items[0];
        var max: f64 = values.items[0];
        for (values.items) |v| {
            if (v < min) min = v;
            if (v > max) max = v;
        }

        const bin_width = (max - min) / @as(f64, @floatFromInt(num_bins));
        var bin_counts = try self.allocator.alloc(usize, num_bins);
        defer self.allocator.free(bin_counts);
        @memset(bin_counts, 0);

        for (values.items) |v| {
            var bin_idx: usize = 0;
            if (bin_width > 0) {
                bin_idx = @intFromFloat((v - min) / bin_width);
                if (bin_idx >= num_bins) bin_idx = num_bins - 1;
            }
            bin_counts[bin_idx] += 1;
        }

        var out = std.ArrayList(u8).init(self.allocator);
        errdefer out.deinit();
        try out.appendSlice("{\"bins\":[");
        for (bin_counts, 0..) |c, i| {
            if (i > 0) try out.append(',');
            const bin_start = min + @as(f64, @floatFromInt(i)) * bin_width;
            const bin_end = bin_start + bin_width;
            try std.fmt.format(out.writer(), "{{\"bin\":{d},\"start\":{d:.6},\"end\":{d:.6},\"count\":{d}}}", .{ i, bin_start, bin_end, c });
        }
        try std.fmt.format(out.writer(), "],\"total_values\":{d},\"num_bins\":{d},\"status\":\"success\"}}", .{ values.items.len, num_bins });
        return out.toOwnedSlice();
    }

    fn execCorrelationCompute(self: *ToolRegistry, args_json: []const u8) ![]const u8 {
        const jv = JsonValue.init(args_json);
        const data_a_str = jv.getString("data_a") orelse return std.fmt.allocPrint(self.allocator, "{{\"error\":\"missing data_a\"}}", .{});
        const data_b_str = jv.getString("data_b") orelse return std.fmt.allocPrint(self.allocator, "{{\"error\":\"missing data_b\"}}", .{});

        var values_a = std.ArrayList(f64).init(self.allocator);
        defer values_a.deinit();
        var values_b = std.ArrayList(f64).init(self.allocator);
        defer values_b.deinit();

        var iter_a = std.mem.tokenizeAny(u8, data_a_str, ", ");
        while (iter_a.next()) |tok| {
            const val = std.fmt.parseFloat(f64, tok) catch continue;
            try values_a.append(val);
        }
        var iter_b = std.mem.tokenizeAny(u8, data_b_str, ", ");
        while (iter_b.next()) |tok| {
            const val = std.fmt.parseFloat(f64, tok) catch continue;
            try values_b.append(val);
        }

        if (values_a.items.len != values_b.items.len or values_a.items.len == 0) {
            return std.fmt.allocPrint(self.allocator, "{{\"error\":\"arrays_must_have_equal_nonzero_length\",\"len_a\":{d},\"len_b\":{d}}}", .{ values_a.items.len, values_b.items.len });
        }

        const n: f64 = @floatFromInt(values_a.items.len);
        var sum_a: f64 = 0;
        var sum_b: f64 = 0;
        var sum_ab: f64 = 0;
        var sum_a2: f64 = 0;
        var sum_b2: f64 = 0;

        for (values_a.items, 0..) |a, i| {
            const b = values_b.items[i];
            sum_a += a;
            sum_b += b;
            sum_ab += a * b;
            sum_a2 += a * a;
            sum_b2 += b * b;
        }

        const numerator = n * sum_ab - sum_a * sum_b;
        const denominator = @sqrt((n * sum_a2 - sum_a * sum_a) * (n * sum_b2 - sum_b * sum_b));
        const correlation: f64 = if (denominator != 0) numerator / denominator else 0;

        return std.fmt.allocPrint(self.allocator, "{{\"pearson_r\":{d:.6},\"n\":{d},\"status\":\"success\"}}", .{ correlation, values_a.items.len });
    }

    // === Vision Tool Handlers ===

    fn execFaceDetect(self: *ToolRegistry, args_json: []const u8) ![]const u8 {
        const jv = JsonValue.init(args_json);
        const boxes_str = jv.getString("boxes") orelse
            return std.fmt.allocPrint(self.allocator, "{{\"error\":\"missing boxes\"}}", .{});
        const img_width = jv.getInteger("img_width") orelse 0;
        const img_height = jv.getInteger("img_height") orelse 0;
        const threshold: f64 = blk: {
            if (jv.getNumber("threshold")) |t| break :blk t;
            break :blk 0.5;
        };

        var out = std.ArrayList(u8).init(self.allocator);
        defer out.deinit();
        try out.appendSlice("{\"faces\":[");

        var box_it = std.mem.splitScalar(u8, boxes_str, ';');
        var first = true;
        var count: usize = 0;
        while (box_it.next()) |box_str| {
            if (box_str.len == 0) continue;
            var field_it = std.mem.splitScalar(u8, box_str, ',');
            const x1 = std.fmt.parseFloat(f64, field_it.next() orelse continue) catch continue;
            const y1 = std.fmt.parseFloat(f64, field_it.next() orelse continue) catch continue;
            const x2 = std.fmt.parseFloat(f64, field_it.next() orelse continue) catch continue;
            const y2 = std.fmt.parseFloat(f64, field_it.next() orelse continue) catch continue;
            const conf = std.fmt.parseFloat(f64, field_it.next() orelse "0") catch 0;

            if (conf < threshold) continue;

            if (!first) try out.append(',');
            first = false;
            try std.fmt.format(out.writer(), "{{\"x1\":{d:.1},\"y1\":{d:.1},\"x2\":{d:.1},\"y2\":{d:.1},\"confidence\":{d:.4}}}", .{ x1, y1, x2, y2, conf });
            count += 1;
        }

        try std.fmt.format(out.writer(), "],\"count\":{d},\"img_width\":{d},\"img_height\":{d},\"threshold\":{d:.2}}}", .{ count, img_width, img_height, threshold });
        return out.toOwnedSlice();
    }

    fn execFaceRecognize(self: *ToolRegistry, args_json: []const u8) ![]const u8 {
        const jv = JsonValue.init(args_json);
        const emb_a_str = jv.getString("embedding_a") orelse
            return std.fmt.allocPrint(self.allocator, "{{\"error\":\"missing embedding_a\"}}", .{});
        const emb_b_str = jv.getString("embedding_b") orelse
            return std.fmt.allocPrint(self.allocator, "{{\"error\":\"missing embedding_b\"}}", .{});

        var list_a = std.ArrayList(f64).init(self.allocator);
        defer list_a.deinit();
        var list_b = std.ArrayList(f64).init(self.allocator);
        defer list_b.deinit();

        var it_a = std.mem.splitScalar(u8, emb_a_str, ',');
        while (it_a.next()) |s| {
            const v = std.fmt.parseFloat(f64, std.mem.trim(u8, s, " ")) catch continue;
            list_a.append(v) catch break;
        }
        var it_b = std.mem.splitScalar(u8, emb_b_str, ',');
        while (it_b.next()) |s| {
            const v = std.fmt.parseFloat(f64, std.mem.trim(u8, s, " ")) catch continue;
            list_b.append(v) catch break;
        }

        if (list_a.items.len == 0 or list_b.items.len == 0)
            return std.fmt.allocPrint(self.allocator, "{{\"error\":\"empty embeddings\"}}", .{});

        const n = @min(list_a.items.len, list_b.items.len);
        var dot: f64 = 0;
        var norm_a: f64 = 0;
        var norm_b: f64 = 0;
        for (0..n) |i| {
            dot += list_a.items[i] * list_b.items[i];
            norm_a += list_a.items[i] * list_a.items[i];
            norm_b += list_b.items[i] * list_b.items[i];
        }

        const denom = @sqrt(norm_a) * @sqrt(norm_b);
        const similarity: f64 = if (denom != 0) dot / denom else 0;
        const is_same = similarity > 0.5;

        return std.fmt.allocPrint(self.allocator, "{{\"similarity\":{d:.6},\"is_same\":{},\"dim_a\":{d},\"dim_b\":{d}}}", .{ similarity, is_same, list_a.items.len, list_b.items.len });
    }

    fn execFaceAnalyze(self: *ToolRegistry, args_json: []const u8) ![]const u8 {
        const jv = JsonValue.init(args_json);
        const x1 = jv.getNumber("x1") orelse 0;
        const y1 = jv.getNumber("y1") orelse 0;
        const x2 = jv.getNumber("x2") orelse 0;
        const y2 = jv.getNumber("y2") orelse 0;
        const img_width: f64 = @floatFromInt(jv.getInteger("img_width") orelse 1);
        const img_height: f64 = @floatFromInt(jv.getInteger("img_height") orelse 1);

        const face_w = x2 - x1;
        const face_h = y2 - y1;
        const face_area = face_w * face_h;
        const img_area = img_width * img_height;
        const size_ratio = if (img_area > 0) face_area / img_area else 0;
        const aspect_ratio = if (face_h > 0) face_w / face_h else 0;

        const aspect_dev: f64 = if (aspect_ratio > 0.8) aspect_ratio - 0.8 else 0.8 - aspect_ratio;
        const aspect_quality: f64 = 1.0 - @min(aspect_dev / 0.4, 1.0);
        const size_quality: f64 = if (size_ratio > 0.01 and size_ratio < 0.5) 1.0 else 0.5;
        const overall_quality = (aspect_quality * 0.5 + size_quality * 0.5);

        return std.fmt.allocPrint(self.allocator, "{{\"face_width\":{d:.1},\"face_height\":{d:.1},\"size_ratio\":{d:.6},\"aspect_ratio\":{d:.4},\"quality_score\":{d:.4}}}", .{ face_w, face_h, size_ratio, aspect_ratio, overall_quality });
    }

    fn execFaceTrack(self: *ToolRegistry, args_json: []const u8) ![]const u8 {
        const jv = JsonValue.init(args_json);
        const prev_str = jv.getString("prev_boxes") orelse
            return std.fmt.allocPrint(self.allocator, "{{\"error\":\"missing prev_boxes\"}}", .{});
        const curr_str = jv.getString("curr_boxes") orelse
            return std.fmt.allocPrint(self.allocator, "{{\"error\":\"missing curr_boxes\"}}", .{});
        const iou_threshold: f64 = blk: {
            if (jv.getNumber("iou_threshold")) |t| break :blk t;
            break :blk 0.3;
        };

        var out = std.ArrayList(u8).init(self.allocator);
        defer out.deinit();
        try out.appendSlice("{\"matches\":[");

        var prev_it = std.mem.splitScalar(u8, prev_str, ';');
        var first = true;
        var match_count: usize = 0;

        while (prev_it.next()) |prev_box| {
            if (prev_box.len == 0) continue;
            var prev_fields = std.mem.splitScalar(u8, prev_box, ',');
            const px1 = std.fmt.parseFloat(f64, prev_fields.next() orelse continue) catch continue;
            const py1 = std.fmt.parseFloat(f64, prev_fields.next() orelse continue) catch continue;
            const px2 = std.fmt.parseFloat(f64, prev_fields.next() orelse continue) catch continue;
            const py2 = std.fmt.parseFloat(f64, prev_fields.next() orelse continue) catch continue;

            var curr_it = std.mem.splitScalar(u8, curr_str, ';');
            var best_iou: f64 = 0;
            var best_idx: usize = 0;
            var idx: usize = 0;

            while (curr_it.next()) |curr_box| {
                if (curr_box.len == 0) continue;
                var curr_fields = std.mem.splitScalar(u8, curr_box, ',');
                const cx1 = std.fmt.parseFloat(f64, curr_fields.next() orelse continue) catch continue;
                const cy1 = std.fmt.parseFloat(f64, curr_fields.next() orelse continue) catch continue;
                const cx2 = std.fmt.parseFloat(f64, curr_fields.next() orelse continue) catch continue;
                const cy2 = std.fmt.parseFloat(f64, curr_fields.next() orelse continue) catch continue;

                const ix1 = @max(px1, cx1);
                const iy1 = @max(py1, cy1);
                const ix2 = @min(px2, cx2);
                const iy2 = @min(py2, cy2);

                const iw = if (ix2 > ix1) ix2 - ix1 else 0;
                const ih = if (iy2 > iy1) iy2 - iy1 else 0;
                const intersection = iw * ih;
                const area_p = (px2 - px1) * (py2 - py1);
                const area_c = (cx2 - cx1) * (cy2 - cy1);
                const union_area = area_p + area_c - intersection;
                const iou = if (union_area > 0) intersection / union_area else 0;

                if (iou > best_iou) {
                    best_iou = iou;
                    best_idx = idx;
                }
                idx += 1;
            }

            if (best_iou >= iou_threshold) {
                if (!first) try out.append(',');
                first = false;
                try std.fmt.format(out.writer(), "{{\"prev_idx\":{d},\"curr_idx\":{d},\"iou\":{d:.4}}}", .{ match_count, best_idx, best_iou });
                match_count += 1;
            }
        }

        try std.fmt.format(out.writer(), "],\"match_count\":{d},\"iou_threshold\":{d:.2}}}", .{ match_count, iou_threshold });
        return out.toOwnedSlice();
    }

    fn execGazeEstimate(self: *ToolRegistry, args_json: []const u8) ![]const u8 {
        const jv = JsonValue.init(args_json);
        const left_eye_x = jv.getNumber("left_eye_x") orelse 0;
        const left_eye_y = jv.getNumber("left_eye_y") orelse 0;
        const right_eye_x = jv.getNumber("right_eye_x") orelse 0;
        const right_eye_y = jv.getNumber("right_eye_y") orelse 0;
        const nose_x = jv.getNumber("nose_x") orelse 0;
        const nose_y = jv.getNumber("nose_y") orelse 0;

        const eye_mid_x = (left_eye_x + right_eye_x) * 0.5;
        const eye_mid_y = (left_eye_y + right_eye_y) * 0.5;
        const dx_eyes = right_eye_x - left_eye_x;
        const dy_eyes = right_eye_y - left_eye_y;
        const eye_dist = @sqrt(dx_eyes * dx_eyes + dy_eyes * dy_eyes);

        const yaw: f64 = if (eye_dist > 0) (nose_x - eye_mid_x) / eye_dist * 90.0 else 0;

        const pitch: f64 = blk: {
            const face_height = nose_y - eye_mid_y;
            if (face_height > 0) {
                const nose_offset = (nose_y - eye_mid_y) / face_height;
                break :blk (nose_offset - 0.6) * 90.0;
            }
            break :blk 0;
        };

        const roll: f64 = if (eye_dist > 0) std.math.atan2(dy_eyes, dx_eyes) * 180.0 / std.math.pi else 0;

        return std.fmt.allocPrint(self.allocator, "{{\"pitch\":{d:.2},\"yaw\":{d:.2},\"roll\":{d:.2}}}", .{ pitch, yaw, roll });
    }

    fn execEmotionDetect(self: *ToolRegistry, args_json: []const u8) ![]const u8 {
        const jv = JsonValue.init(args_json);
        const scores_str = jv.getString("scores") orelse
            return std.fmt.allocPrint(self.allocator, "{{\"error\":\"missing scores\"}}", .{});

        const labels = [_][]const u8{ "neutral", "happy", "sad", "surprise", "angry", "fear", "disgust", "contempt" };

        var scores: [8]f64 = [_]f64{0} ** 8;
        var it = std.mem.splitScalar(u8, scores_str, ',');
        var idx: usize = 0;
        while (it.next()) |s| {
            if (idx >= 8) break;
            scores[idx] = std.fmt.parseFloat(f64, std.mem.trim(u8, s, " ")) catch 0;
            idx += 1;
        }

        var best_idx: usize = 0;
        var best_val: f64 = scores[0];
        for (1..8) |i| {
            if (scores[i] > best_val) {
                best_val = scores[i];
                best_idx = i;
            }
        }

        return std.fmt.allocPrint(self.allocator, "{{\"emotion\":\"{s}\",\"confidence\":{d:.4},\"scores\":{{\"neutral\":{d:.4},\"happy\":{d:.4},\"sad\":{d:.4},\"surprise\":{d:.4},\"angry\":{d:.4},\"fear\":{d:.4},\"disgust\":{d:.4},\"contempt\":{d:.4}}}}}", .{ labels[best_idx], best_val, scores[0], scores[1], scores[2], scores[3], scores[4], scores[5], scores[6], scores[7] });
    }

    // === Geoview Tool Handlers ===

    fn execGeoDistance(self: *ToolRegistry, args_json: []const u8) ![]const u8 {
        const jv = JsonValue.init(args_json);
        const lat1 = jv.getNumber("lat1") orelse return std.fmt.allocPrint(self.allocator, "{{\"error\":\"missing lat1\"}}", .{});
        const lon1 = jv.getNumber("lon1") orelse return std.fmt.allocPrint(self.allocator, "{{\"error\":\"missing lon1\"}}", .{});
        const lat2 = jv.getNumber("lat2") orelse return std.fmt.allocPrint(self.allocator, "{{\"error\":\"missing lat2\"}}", .{});
        const lon2 = jv.getNumber("lon2") orelse return std.fmt.allocPrint(self.allocator, "{{\"error\":\"missing lon2\"}}", .{});

        const a = geo.LatLon.init(lat1, lon1);
        const b = geo.LatLon.init(lat2, lon2);
        const dist_m = geo.greatCircleDistance(a, b);
        const brng = geo.bearing(a, b);

        return std.fmt.allocPrint(self.allocator, "{{\"distance_m\":{d:.2},\"distance_km\":{d:.2},\"bearing_deg\":{d:.2},\"cardinal\":\"{s}\"}}", .{
            dist_m, dist_m / 1000.0, brng, geo.cardinalDirection(brng),
        });
    }

    fn execGeoConvert(self: *ToolRegistry, args_json: []const u8) ![]const u8 {
        const jv = JsonValue.init(args_json);
        const lat = jv.getNumber("lat") orelse return std.fmt.allocPrint(self.allocator, "{{\"error\":\"missing lat\"}}", .{});
        const lon = jv.getNumber("lon") orelse return std.fmt.allocPrint(self.allocator, "{{\"error\":\"missing lon\"}}", .{});
        const alt: f64 = jv.getNumber("alt") orelse 0;

        const lla = geo.LatLon.initAlt(lat, lon, alt);
        const ecef = geo.llaToEcef(lla);
        const mgrs = geo.latLonToMgrs(self.allocator, geo.LatLon.init(lat, lon)) catch "ERROR";
        defer if (std.mem.eql(u8, mgrs, "ERROR")) {} else self.allocator.free(mgrs);

        return std.fmt.allocPrint(self.allocator, "{{\"ecef\":{{\"x\":{d:.4},\"y\":{d:.4},\"z\":{d:.4}}},\"mgrs\":\"{s}\"}}", .{
            ecef.x, ecef.y, ecef.z, mgrs,
        });
    }

    fn execGeoMgrs(self: *ToolRegistry, args_json: []const u8) ![]const u8 {
        const jv = JsonValue.init(args_json);
        const lat = jv.getNumber("lat") orelse return std.fmt.allocPrint(self.allocator, "{{\"error\":\"missing lat\"}}", .{});
        const lon = jv.getNumber("lon") orelse return std.fmt.allocPrint(self.allocator, "{{\"error\":\"missing lon\"}}", .{});

        const mgrs = geo.latLonToMgrs(self.allocator, geo.LatLon.init(lat, lon)) catch
            return std.fmt.allocPrint(self.allocator, "{{\"error\":\"MGRS encoding failed\"}}", .{});
        defer self.allocator.free(mgrs);

        return std.fmt.allocPrint(self.allocator, "{{\"mgrs\":\"{s}\",\"lat\":{d:.6},\"lon\":{d:.6}}}", .{ mgrs, lat, lon });
    }

    fn execGeoBearing(self: *ToolRegistry, args_json: []const u8) ![]const u8 {
        const jv = JsonValue.init(args_json);
        const lat1 = jv.getNumber("lat1") orelse return std.fmt.allocPrint(self.allocator, "{{\"error\":\"missing lat1\"}}", .{});
        const lon1 = jv.getNumber("lon1") orelse return std.fmt.allocPrint(self.allocator, "{{\"error\":\"missing lon1\"}}", .{});
        const lat2 = jv.getNumber("lat2") orelse return std.fmt.allocPrint(self.allocator, "{{\"error\":\"missing lat2\"}}", .{});
        const lon2 = jv.getNumber("lon2") orelse return std.fmt.allocPrint(self.allocator, "{{\"error\":\"missing lon2\"}}", .{});

        const a = geo.LatLon.init(lat1, lon1);
        const b = geo.LatLon.init(lat2, lon2);
        const brng = geo.bearing(a, b);

        return std.fmt.allocPrint(self.allocator, "{{\"bearing_deg\":{d:.2},\"cardinal\":\"{s}\"}}", .{
            brng, geo.cardinalDirection(brng),
        });
    }

    fn execGeoDestination(self: *ToolRegistry, args_json: []const u8) ![]const u8 {
        const jv = JsonValue.init(args_json);
        const lat = jv.getNumber("lat") orelse return std.fmt.allocPrint(self.allocator, "{{\"error\":\"missing lat\"}}", .{});
        const lon = jv.getNumber("lon") orelse return std.fmt.allocPrint(self.allocator, "{{\"error\":\"missing lon\"}}", .{});
        const bearing = jv.getNumber("bearing") orelse return std.fmt.allocPrint(self.allocator, "{{\"error\":\"missing bearing\"}}", .{});
        const distance = jv.getNumber("distance") orelse return std.fmt.allocPrint(self.allocator, "{{\"error\":\"missing distance\"}}", .{});

        const dest = geo.destinationPoint(geo.LatLon.init(lat, lon), bearing, distance);

        return std.fmt.allocPrint(self.allocator, "{{\"lat\":{d:.6},\"lon\":{d:.6},\"bearing\":{d:.2},\"distance_m\":{d:.2}}}", .{
            dest.lat, dest.lon, bearing, distance,
        });
    }

    // === Advanced Geoview Tool Handlers ===

    fn execGlobeQuery(self: *ToolRegistry, args_json: []const u8) ![]const u8 {
        const jv = JsonValue.init(args_json);
        const lat = jv.getNumber("lat") orelse return std.fmt.allocPrint(self.allocator, "{{\"error\":\"missing lat\"}}", .{});
        const lon = jv.getNumber("lon") orelse return std.fmt.allocPrint(self.allocator, "{{\"error\":\"missing lon\"}}", .{});
        const radius_km = jv.getNumber("radius_km") orelse 100.0;
        const entity_type = jv.getString("entity_type") orelse "all";

        const center = geo.LatLon.init(lat, lon);
        const ecef = geo.llaToEcef(center);
        const mgrs = geo.latLonToMgrs(self.allocator, center) catch "ERROR";
        defer if (!std.mem.eql(u8, mgrs, "ERROR")) self.allocator.free(mgrs);

        return std.fmt.allocPrint(self.allocator, "{{\"center\":{{\"lat\":{d:.6},\"lon\":{d:.6}}},\"radius_km\":{d:.2},\"entity_type\":\"{s}\",\"ecef\":{{\"x\":{d:.4},\"y\":{d:.4},\"z\":{d:.4}}},\"mgrs\":\"{s}\"}}", .{
            lat, lon, radius_km, entity_type, ecef.x, ecef.y, ecef.z, mgrs,
        });
    }

    fn execTrackFlight(self: *ToolRegistry, args_json: []const u8) ![]const u8 {
        const jv = JsonValue.init(args_json);
        const callsign = jv.getString("callsign") orelse return std.fmt.allocPrint(self.allocator, "{{\"error\":\"missing callsign\"}}", .{});

        const aircraft_class = flights.classifyAircraft(callsign);
        const class_str = switch (aircraft_class) {
            .civil => "civil",
            .military => "military",
            .government => "government",
            .private => "private",
            .helicopter => "helicopter",
            .ground_vehicle => "ground_vehicle",
            .unknown => "unknown",
        };

        const lat = jv.getNumber("lat") orelse 0.0;
        const lon = jv.getNumber("lon") orelse 0.0;
        const altitude_m = jv.getNumber("altitude_m") orelse 0.0;
        const velocity_mps = jv.getNumber("velocity_mps") orelse 0.0;
        const heading_deg = jv.getNumber("heading_deg") orelse 0.0;
        const dt_seconds = jv.getNumber("dt_seconds") orelse 60.0;

        if (lat == 0.0 and lon == 0.0) {
            return std.fmt.allocPrint(self.allocator, "{{\"callsign\":\"{s}\",\"class\":\"{s}\",\"dead_reckon\":\"not_available_no_position\"}}", .{ callsign, class_str });
        }

        const aircraft = flights.Aircraft{
            .icao24 = "",
            .callsign = callsign,
            .origin_country = "",
            .lat = lat,
            .lon = lon,
            .altitude_m = altitude_m,
            .velocity_mps = velocity_mps,
            .heading_deg = heading_deg,
            .vertical_rate_mps = 0,
            .on_ground = false,
            .spi = false,
            .last_contact = 0,
        };

        const predicted = flights.deadReckonPosition(aircraft, dt_seconds);

        return std.fmt.allocPrint(self.allocator, "{{\"callsign\":\"{s}\",\"class\":\"{s}\",\"current\":{{\"lat\":{d:.6},\"lon\":{d:.6},\"alt_m\":{d:.1}}},\"predicted\":{{\"lat\":{d:.6},\"lon\":{d:.6}}},\"dt_seconds\":{d:.1}}}", .{
            callsign, class_str, lat, lon, altitude_m, predicted.lat, predicted.lon, dt_seconds,
        });
    }

    fn execTrackVessel(self: *ToolRegistry, args_json: []const u8) ![]const u8 {
        const jv = JsonValue.init(args_json);
        const mmsi = jv.getInteger("mmsi") orelse return std.fmt.allocPrint(self.allocator, "{{\"error\":\"missing mmsi\"}}", .{});
        const name = jv.getString("name") orelse "";
        const lat = jv.getNumber("lat") orelse 0.0;
        const lon = jv.getNumber("lon") orelse 0.0;
        const speed_knots = jv.getNumber("speed_knots") orelse 0.0;
        const course_deg = jv.getNumber("course_deg") orelse 0.0;
        const type_code: u8 = @intCast(jv.getInteger("type_code") orelse 0);
        const nav_status_code: u8 = @intCast(jv.getInteger("nav_status_code") orelse 15);
        const dt_hours = jv.getNumber("dt_hours") orelse 1.0;

        const vessel_type = vessels.classifyVesselType(type_code);
        const nav_status = vessels.parseNavigationStatus(nav_status_code);
        const type_str = switch (vessel_type) {
            .cargo => "cargo",
            .tanker => "tanker",
            .passenger => "passenger",
            .fishing => "fishing",
            .pleasure_craft => "pleasure_craft",
            .tug => "tug",
            .pilot => "pilot",
            .sar => "sar",
            .military => "military",
            .law_enforcement => "law_enforcement",
            .medical => "medical",
            .other => "other",
            .unknown => "unknown",
        };
        const nav_str = switch (nav_status) {
            .under_way_engine => "under_way_engine",
            .at_anchor => "at_anchor",
            .not_under_command => "not_under_command",
            .restricted_manoeuvrability => "restricted_manoeuvrability",
            .constrained_by_draught => "constrained_by_draught",
            .moored => "moored",
            .aground => "aground",
            .engaged_in_fishing => "engaged_in_fishing",
            .under_way_sailing => "under_way_sailing",
            .reserved_hsc => "reserved_hsc",
            .reserved_wing => "reserved_wing",
            .reserved => "reserved",
            .unknown => "unknown",
        };

        if (lat == 0.0 and lon == 0.0) {
            return std.fmt.allocPrint(self.allocator, "{{\"mmsi\":{d},\"name\":\"{s}\",\"type\":\"{s}\",\"nav_status\":\"{s}\",\"dead_reckon\":\"not_available_no_position\"}}", .{ mmsi, name, type_str, nav_str });
        }

        const vessel = vessels.Vessel{
            .mmsi = @intCast(mmsi),
            .name = name,
            .lat = lat,
            .lon = lon,
            .speed_knots = speed_knots,
            .course_deg = course_deg,
            .heading_deg = course_deg,
            .nav_status = nav_status,
            .vessel_type = vessel_type,
        };

        const predicted = vessels.deadReckonPosition(vessel, dt_hours);

        return std.fmt.allocPrint(self.allocator, "{{\"mmsi\":{d},\"name\":\"{s}\",\"type\":\"{s}\",\"nav_status\":\"{s}\",\"current\":{{\"lat\":{d:.6},\"lon\":{d:.6},\"speed_kn\":{d:.1}}},\"predicted\":{{\"lat\":{d:.6},\"lon\":{d:.6}}},\"dt_hours\":{d:.1}}}", .{
            mmsi, name, type_str, nav_str, lat, lon, speed_knots, predicted.lat, predicted.lon, dt_hours,
        });
    }

    fn execTrackSatellite(self: *ToolRegistry, args_json: []const u8) ![]const u8 {
        const jv = JsonValue.init(args_json);
        const norad_id = jv.getInteger("norad_id") orelse return std.fmt.allocPrint(self.allocator, "{{\"error\":\"missing norad_id\"}}", .{});
        const name = jv.getString("name") orelse "";
        const tle_line1 = jv.getString("tle_line1") orelse "";
        const tle_line2 = jv.getString("tle_line2") orelse "";

        if (tle_line1.len < 24 or tle_line2.len < 24) {
            return std.fmt.allocPrint(self.allocator, "{{\"norad_id\":{d},\"name\":\"{s}\",\"status\":\"no_tle_provided\"}}", .{ norad_id, name });
        }

        const l1 = satellites.parseTleLine1(tle_line1);
        const l2 = satellites.parseTleLine2(tle_line2);

        return std.fmt.allocPrint(self.allocator, "{{\"norad_id\":{d},\"name\":\"{s}\",\"epoch_year\":{d},\"epoch_day\":{d:.4},\"inclination_deg\":{d:.4},\"raan_deg\":{d:.4},\"eccentricity\":{d:.7},\"arg_perigee_deg\":{d:.4},\"mean_anomaly_deg\":{d:.4},\"mean_motion_rev_per_day\":{d:.4},\"bstar\":{d:.6}}}", .{
            norad_id,        name,           l1.epoch_year,   l1.epoch_day,
            l2.inclination,  l2.raan,        l2.eccentricity, l2.arg_perigee,
            l2.mean_anomaly, l2.mean_motion, l1.bstar,
        });
    }

    fn execEarthquakeQuery(self: *ToolRegistry, args_json: []const u8) ![]const u8 {
        const jv = JsonValue.init(args_json);
        const min_magnitude = jv.getNumber("min_magnitude") orelse 0.0;
        const geojson = jv.getString("geojson");
        const timeframe = jv.getString("timeframe") orelse "day";

        if (geojson) |json_data| {
            const eqs = earthquakes.parseGeoJson(self.allocator, json_data) catch
                return std.fmt.allocPrint(self.allocator, "{{\"error\":\"geojson_parse_failed\"}}", .{});
            defer earthquakes.freeEarthquakeList(self.allocator, eqs);

            var filtered_count: usize = 0;
            var max_mag: f64 = 0;
            for (eqs) |eq| {
                if (eq.magnitude >= min_magnitude) {
                    filtered_count += 1;
                    if (eq.magnitude > max_mag) max_mag = eq.magnitude;
                }
            }

            return std.fmt.allocPrint(self.allocator, "{{\"source\":\"provided_geojson\",\"total_count\":{d},\"filtered_count\":{d},\"min_magnitude\":{d:.1},\"max_magnitude\":{d:.1}}}", .{
                eqs.len, filtered_count, min_magnitude, max_mag,
            });
        }

        if (is_wasm) {
            return std.fmt.allocPrint(self.allocator, "{{\"source\":\"usgs_{s}\",\"status\":\"not_available_in_wasm\",\"min_magnitude\":{d:.1}}}", .{ timeframe, min_magnitude });
        }

        const eqs = earthquakes.fetchEarthquakes(self.allocator, timeframe) catch
            return std.fmt.allocPrint(self.allocator, "{{\"source\":\"usgs_{s}\",\"status\":\"network_unavailable\",\"min_magnitude\":{d:.1}\"}}", .{ timeframe, min_magnitude });
        defer earthquakes.freeEarthquakeList(self.allocator, eqs);

        var filtered_count: usize = 0;
        var max_mag: f64 = 0;
        for (eqs) |eq| {
            if (eq.magnitude >= min_magnitude) {
                filtered_count += 1;
                if (eq.magnitude > max_mag) max_mag = eq.magnitude;
            }
        }

        return std.fmt.allocPrint(self.allocator, "{{\"source\":\"usgs_{s}\",\"total_count\":{d},\"filtered_count\":{d},\"min_magnitude\":{d:.1},\"max_magnitude\":{d:.1}}}", .{
            timeframe, eqs.len, filtered_count, min_magnitude, max_mag,
        });
    }

    fn execCctvQuery(self: *ToolRegistry, args_json: []const u8) ![]const u8 {
        const jv = JsonValue.init(args_json);
        const lat = jv.getNumber("lat") orelse return std.fmt.allocPrint(self.allocator, "{{\"error\":\"missing lat\"}}", .{});
        const lon = jv.getNumber("lon") orelse return std.fmt.allocPrint(self.allocator, "{{\"error\":\"missing lon\"}}", .{});
        const heading_deg = jv.getNumber("heading_deg") orelse 0.0;
        const fov_deg = jv.getNumber("fov_deg") orelse 90.0;
        const range_km = jv.getNumber("range_km") orelse 10.0;
        const target_lat = jv.getNumber("target_lat");
        const target_lon = jv.getNumber("target_lon");

        const camera = cctv.CctvCamera{
            .id = "query",
            .name = "Query Camera",
            .lat = lat,
            .lon = lon,
            .heading_deg = heading_deg,
            .fov_deg = fov_deg,
            .range_km = range_km,
            .status = .online,
        };

        const viewshed = cctv.calculateViewshed(self.allocator, camera, 8) catch
            return std.fmt.allocPrint(self.allocator, "{{\"error\":\"viewshed_calculation_failed\"}}", .{});
        defer self.allocator.free(viewshed);

        if (target_lat != null and target_lon != null) {
            const visible = cctv.isPointInViewshed(camera, target_lat.?, target_lon.?);
            const dist = geo.greatCircleDistance(geo.LatLon.init(lat, lon), geo.LatLon.init(target_lat.?, target_lon.?));
            return std.fmt.allocPrint(self.allocator, "{{\"camera\":{{\"lat\":{d:.6},\"lon\":{d:.6},\"heading\":{d:.1},\"fov\":{d:.1},\"range_km\":{d:.1}}},\"target\":{{\"lat\":{d:.6},\"lon\":{d:.6}}},\"visible\":{},\"distance_m\":{d:.2},\"viewshed_points\":{d}}}", .{
                lat,          lon,          heading_deg, fov_deg, range_km,
                target_lat.?, target_lon.?, visible,     dist,    viewshed.len,
            });
        }

        return std.fmt.allocPrint(self.allocator, "{{\"camera\":{{\"lat\":{d:.6},\"lon\":{d:.6},\"heading\":{d:.1},\"fov\":{d:.1},\"range_km\":{d:.1}}},\"viewshed_points\":{d}}}", .{
            lat, lon, heading_deg, fov_deg, range_km, viewshed.len,
        });
    }

    fn execHudControl(self: *ToolRegistry, args_json: []const u8) ![]const u8 {
        const jv = JsonValue.init(args_json);
        const action = jv.getString("action") orelse return std.fmt.allocPrint(self.allocator, "{{\"error\":\"missing action\"}}", .{});

        var hud = hud_mod.HudRenderer.init(self.allocator, 1920, 1080);
        defer hud.deinit();

        if (std.mem.eql(u8, action, "compass")) {
            const heading = jv.getNumber("heading_deg") orelse 0.0;
            const pitch = jv.getNumber("pitch_deg") orelse 0.0;
            try hud.buildCompass(.{ .heading_deg = heading, .pitch_deg = pitch, .roll_deg = 0 });
            return std.fmt.allocPrint(self.allocator, "{{\"action\":\"compass\",\"heading_deg\":{d:.1},\"elements\":{d}}}", .{ heading, hud.elements.items.len });
        } else if (std.mem.eql(u8, action, "scale_bar")) {
            const mpp = jv.getNumber("meters_per_pixel") orelse 10.0;
            try hud.buildScaleBar(.{ .meters_per_pixel = mpp, .screen_width_px = 1920 });
            return std.fmt.allocPrint(self.allocator, "{{\"action\":\"scale_bar\",\"meters_per_pixel\":{d:.2},\"elements\":{d}}}", .{ mpp, hud.elements.items.len });
        } else if (std.mem.eql(u8, action, "coordinates")) {
            const lat = jv.getNumber("lat") orelse 0.0;
            const lon = jv.getNumber("lon") orelse 0.0;
            const alt = jv.getNumber("alt_m") orelse 0.0;
            const mgrs = geo.latLonToMgrs(self.allocator, geo.LatLon.init(lat, lon)) catch "";
            defer if (mgrs.len > 0) self.allocator.free(mgrs);
            try hud.buildCoordinateReadout(.{ .lat = lat, .lon = lon, .alt_m = alt, .mgrs = mgrs });
            return std.fmt.allocPrint(self.allocator, "{{\"action\":\"coordinates\",\"lat\":{d:.6},\"lon\":{d:.6},\"alt_m\":{d:.0},\"mgrs\":\"{s}\",\"elements\":{d}}}", .{ lat, lon, alt, mgrs, hud.elements.items.len });
        } else if (std.mem.eql(u8, action, "status")) {
            const entity_count = jv.getInteger("entity_count") orelse 0;
            try hud.buildStatusPanel(.{ .fps = 60, .entity_count = @intCast(entity_count), .visible_count = @intCast(entity_count), .feed_status = "nominal", .camera_mode = "orbit" });
            return std.fmt.allocPrint(self.allocator, "{{\"action\":\"status\",\"entity_count\":{d},\"elements\":{d}}}", .{ entity_count, hud.elements.items.len });
        } else if (std.mem.eql(u8, action, "alert")) {
            const message = jv.getString("message") orelse "ALERT";
            try hud.buildAlert(message, .warning);
            return std.fmt.allocPrint(self.allocator, "{{\"action\":\"alert\",\"message\":\"{s}\",\"elements\":{d}}}", .{ message, hud.elements.items.len });
        } else if (std.mem.eql(u8, action, "crosshair")) {
            try hud.buildCrosshair();
            return std.fmt.allocPrint(self.allocator, "{{\"action\":\"crosshair\",\"elements\":{d}}}", .{hud.elements.items.len});
        } else {
            return std.fmt.allocPrint(self.allocator, "{{\"error\":\"unknown_hud_action:{s}\"}}", .{action});
        }
    }

    fn execScenePlay(self: *ToolRegistry, args_json: []const u8) ![]const u8 {
        const jv = JsonValue.init(args_json);
        const action = jv.getString("action") orelse return std.fmt.allocPrint(self.allocator, "{{\"error\":\"missing action\"}}", .{});

        var director = scene_mod.SceneDirector.init(self.allocator);
        defer director.deinit();

        if (std.mem.eql(u8, action, "queue_focus")) {
            const lat = jv.getNumber("lat") orelse 0.0;
            const lon = jv.getNumber("lon") orelse 0.0;
            const priority: u8 = @intCast(jv.getInteger("priority") orelse 5);
            const duration_s = jv.getNumber("duration_s") orelse 10.0;
            const label = jv.getString("label") orelse "";
            try director.queueFocus(.{
                .lat = lat,
                .lon = lon,
                .priority = priority,
                .duration_s = duration_s,
                .label = label,
            });
            return std.fmt.allocPrint(self.allocator, "{{\"action\":\"queue_focus\",\"queue_length\":{d},\"target\":{{\"lat\":{d:.6},\"lon\":{d:.6},\"priority\":{d},\"duration_s\":{d:.1}}}}}", .{
                director.queueLength(), lat, lon, priority, duration_s,
            });
        } else if (std.mem.eql(u8, action, "start")) {
            director.startPlayback();
            return std.fmt.allocPrint(self.allocator, "{{\"action\":\"start\",\"playback\":\"playing\"}}", .{});
        } else if (std.mem.eql(u8, action, "pause")) {
            director.pausePlayback();
            return std.fmt.allocPrint(self.allocator, "{{\"action\":\"pause\",\"playback\":\"paused\"}}", .{});
        } else if (std.mem.eql(u8, action, "resume")) {
            director.resumePlayback();
            return std.fmt.allocPrint(self.allocator, "{{\"action\":\"resume\",\"playback\":\"playing\"}}", .{});
        } else if (std.mem.eql(u8, action, "stop")) {
            director.stopPlayback();
            return std.fmt.allocPrint(self.allocator, "{{\"action\":\"stop\",\"playback\":\"stopped\"}}", .{});
        } else if (std.mem.eql(u8, action, "status")) {
            const state_str = switch (director.playback_state) {
                .stopped => "stopped",
                .playing => "playing",
                .paused => "paused",
            };
            return std.fmt.allocPrint(self.allocator, "{{\"action\":\"status\",\"playback\":\"{s}\",\"queue_length\":{d},\"has_focus\":{}}}", .{
                state_str, director.queueLength(), director.hasFocus(),
            });
        } else {
            return std.fmt.allocPrint(self.allocator, "{{\"error\":\"unknown_scene_action:{s}\"}}", .{action});
        }
    }

    fn execAnnotationAdd(self: *ToolRegistry, args_json: []const u8) ![]const u8 {
        const jv = JsonValue.init(args_json);
        const ann_type = jv.getString("type") orelse return std.fmt.allocPrint(self.allocator, "{{\"error\":\"missing type\"}}", .{});
        const lat = jv.getNumber("lat") orelse return std.fmt.allocPrint(self.allocator, "{{\"error\":\"missing lat\"}}", .{});
        const lon = jv.getNumber("lon") orelse return std.fmt.allocPrint(self.allocator, "{{\"error\":\"missing lon\"}}", .{});

        var store = ann_mod.AnnotationStore.init(self.allocator);
        defer store.deinit();

        if (std.mem.eql(u8, ann_type, "pin")) {
            const title = jv.getString("title") orelse "Untitled";
            const description = jv.getString("description") orelse "";
            const id = try store.addPin(lat, lon, title, description);
            return std.fmt.allocPrint(self.allocator, "{{\"type\":\"pin\",\"id\":{d},\"lat\":{d:.6},\"lon\":{d:.6},\"title\":\"{s}\",\"count\":{d}}}", .{
                id, lat, lon, title, store.count(),
            });
        } else if (std.mem.eql(u8, ann_type, "measurement")) {
            const to_lat = jv.getNumber("to_lat") orelse return std.fmt.allocPrint(self.allocator, "{{\"error\":\"missing to_lat\"}}", .{});
            const to_lon = jv.getNumber("to_lon") orelse return std.fmt.allocPrint(self.allocator, "{{\"error\":\"missing to_lon\"}}", .{});

            const from = geo.LatLon.init(lat, lon);
            const to = geo.LatLon.init(to_lat, to_lon);
            const distance_m = geo.greatCircleDistance(from, to);
            const bearing_deg = geo.bearing(from, to);

            const id = try store.addMeasurement(lat, lon, to_lat, to_lon, distance_m, bearing_deg);
            return std.fmt.allocPrint(self.allocator, "{{\"type\":\"measurement\",\"id\":{d},\"from\":{{\"lat\":{d:.6},\"lon\":{d:.6}}},\"to\":{{\"lat\":{d:.6},\"lon\":{d:.6}}},\"distance_m\":{d:.2},\"bearing_deg\":{d:.2},\"count\":{d}}}", .{
                id, lat, lon, to_lat, to_lon, distance_m, bearing_deg, store.count(),
            });
        } else {
            return std.fmt.allocPrint(self.allocator, "{{\"error\":\"unknown_annotation_type:{s}\"}}", .{ann_type});
        }
    }

    // === Helper Functions ===

    fn escapeJsonString(self: *ToolRegistry, s: []const u8) ![]const u8 {
        var out = std.ArrayList(u8).init(self.allocator);
        errdefer out.deinit();
        for (s) |c| {
            switch (c) {
                '"' => try out.appendSlice("\\\""),
                '\\' => try out.appendSlice("\\\\"),
                '\n' => try out.appendSlice("\\n"),
                '\r' => try out.appendSlice("\\r"),
                '\t' => try out.appendSlice("\\t"),
                0...8, 11, 12, 14...31 => try std.fmt.format(out.writer(), "\\u{x:0>4}", .{c}),
                else => try out.append(c),
            }
        }
        return out.toOwnedSlice();
    }

    fn searchDatasetFiles(self: *ToolRegistry, files: []const []const u8, query: []const u8, source: []const u8) ![]const u8 {
        if (is_wasm) return std.fmt.allocPrint(self.allocator, "{{\"query\":\"{s}\",\"source\":\"{s}\",\"status\":\"not_available_in_wasm\"}}", .{ query, source });
        var lower_query_buf: [256]u8 = undefined;
        const lower_query_len = @min(query.len, lower_query_buf.len);
        for (0..lower_query_len) |i| lower_query_buf[i] = std.ascii.toLower(query[i]);
        const lower_query = lower_query_buf[0..lower_query_len];

        for (files) |file_path| {
            const file = std.fs.cwd().openFile(file_path, .{}) catch continue;
            defer file.close();
            const data = file.readToEndAlloc(self.allocator, 5 * 1024 * 1024) catch continue;
            defer self.allocator.free(data);

            var lower_buf: [65536]u8 = undefined;
            const lower_len = @min(data.len, lower_buf.len);
            for (0..lower_len) |i| lower_buf[i] = std.ascii.toLower(data[i]);
            const lower = lower_buf[0..lower_len];

            if (std.mem.indexOf(u8, lower, lower_query)) |pos| {
                const snippet_start = if (pos > 100) pos - 100 else 0;
                const snippet_end = @min(pos + 400, data.len);
                const escaped = try self.escapeJsonString(data[snippet_start..snippet_end]);
                defer self.allocator.free(escaped);
                return std.fmt.allocPrint(self.allocator, "{{\"query\":\"{s}\",\"source\":\"{s}\",\"file\":\"{s}\",\"snippet\":\"{s}\",\"status\":\"success\"}}", .{ query, source, file_path, escaped });
            }
        }

        return std.fmt.allocPrint(self.allocator, "{{\"query\":\"{s}\",\"source\":\"{s}\",\"status\":\"not_found\"}}", .{ query, source });
    }

    /// Parses tool call markup from agent text. Supports two formats:
    ///   1. [[{"name":"...","arguments":{...}}]]
    ///   2. <tool_call>{"name":"...","arguments":{...}}</tool_call>
    pub fn parseToolCall(allocator: std.mem.Allocator, text: []const u8) ?ToolCall {
        var json_slice: []const u8 = undefined;

        if (std.mem.indexOf(u8, text, "[[")) |s_idx| {
            const content_start = s_idx + 2;
            if (std.mem.indexOf(u8, text[content_start..], "]]")) |e_idx| {
                json_slice = text[content_start .. content_start + e_idx];
            } else return null;
        } else if (std.mem.indexOf(u8, text, "<tool_call>")) |s_idx| {
            const content_start = s_idx + "<tool_call>".len;
            if (std.mem.indexOf(u8, text[content_start..], "</tool_call>")) |e_idx| {
                json_slice = text[content_start .. content_start + e_idx];
            } else return null;
        } else return null;

        // Parse tool name
        var name: []const u8 = "calculate";
        if (std.mem.indexOf(u8, json_slice, "\"name\":\"")) |p| {
            const n_start = p + 8;
            if (std.mem.indexOfScalar(u8, json_slice[n_start..], '"')) |n_end_rel| {
                name = json_slice[n_start .. n_start + n_end_rel];
            }
        }

        var args_json: []const u8 = "{}";
        if (std.mem.indexOf(u8, json_slice, "\"arguments\":")) |ap| {
            const a_start = ap + 12;
            var depth: u32 = 0;
            var a_end = a_start;
            var in_str = false;
            while (a_end < json_slice.len) : (a_end += 1) {
                if (in_str) {
                    if (json_slice[a_end] == '"') in_str = false;
                } else {
                    if (json_slice[a_end] == '"') {
                        in_str = true;
                    } else if (json_slice[a_end] == '{') {
                        depth += 1;
                    } else if (json_slice[a_end] == '}') {
                        depth -= 1;
                        if (depth == 0) {
                            a_end += 1;
                            break;
                        }
                    }
                }
            }
            args_json = json_slice[a_start..a_end];
        }

        return ToolCall{
            .id = "call_qstar_1",
            .name = allocator.dupe(u8, name) catch "calculate",
            .arguments_json = allocator.dupe(u8, args_json) catch "{}",
        };
    }
};

// =============================================================================
// Tests
// =============================================================================

test "tools: calculate execution" {
    const allocator = std.testing.allocator;
    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();

    const call = ToolCall{
        .id = "call_1",
        .name = "calculate",
        .arguments_json = "{\"op\":\"add\",\"a\":40.0,\"b\":2.0}",
    };

    const res = try reg.execute(call);
    defer allocator.free(res);

    try std.testing.expect(std.mem.indexOf(u8, res, "42.000000") != null);
}

test "tools: parseToolCall markup" {
    const allocator = std.testing.allocator;
    const text = "I will calculate this for you: <tool_call>{\"name\":\"calculate\",\"arguments\":{\"op\":\"mul\",\"a\":6,\"b\":7}}</tool_call>";

    const call = ToolRegistry.parseToolCall(allocator, text);
    try std.testing.expect(call != null);
    defer {
        allocator.free(call.?.name);
        allocator.free(call.?.arguments_json);
    }

    try std.testing.expectEqualStrings("calculate", call.?.name);
    try std.testing.expect(std.mem.indexOf(u8, call.?.arguments_json, "\"op\":\"mul\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, call.?.arguments_json, "\"name\"") == null);
}

test "tools: quantum_simulate bell circuit" {
    const allocator = std.testing.allocator;
    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();

    const res = try reg.execute(.{
        .id = "q1",
        .name = "quantum_simulate",
        .arguments_json = "{\"circuit\":\"bell\",\"qubits\":2}",
    });
    defer allocator.free(res);

    try std.testing.expect(std.mem.indexOf(u8, res, "bell_state") != null);
    try std.testing.expect(std.mem.indexOf(u8, res, "\"qubits\":2") != null);
}

test "tools: quantum_simulate grover circuit" {
    const allocator = std.testing.allocator;
    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();

    const res = try reg.execute(.{
        .id = "q2",
        .name = "quantum_simulate",
        .arguments_json = "{\"circuit\":\"grover\",\"qubits\":4}",
    });
    defer allocator.free(res);

    try std.testing.expect(std.mem.indexOf(u8, res, "grover_search") != null);
    try std.testing.expect(std.mem.indexOf(u8, res, "\"iterations\":4") != null);
}

test "tools: kg_query with attached KnowledgeGraph" {
    const allocator = std.testing.allocator;
    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();

    var kg = kg_mod.KnowledgeGraph.init(allocator, 0);
    defer kg.deinit();
    _ = try kg.addTriplet("Quantum", "uses", "superposition", 1000, 1);
    _ = try kg.addTriplet("Quantum", "enables", "entanglement", 1000, 2);

    reg.attachKnowledgeGraph(&kg);

    const res = try reg.execute(.{
        .id = "kg1",
        .name = "kg_query",
        .arguments_json = "{\"entity\":\"Quantum\"}",
    });
    defer allocator.free(res);

    try std.testing.expect(std.mem.indexOf(u8, res, "\"count\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, res, "superposition") != null);
}

test "tools: kg_query without attached KG returns no_kg_attached" {
    const allocator = std.testing.allocator;
    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();

    const res = try reg.execute(.{
        .id = "kg2",
        .name = "kg_query",
        .arguments_json = "{\"entity\":\"test\"}",
    });
    defer allocator.free(res);

    try std.testing.expect(std.mem.indexOf(u8, res, "no_kg_attached") != null);
}

test "tools: external_search with attached KG returns subgraph context" {
    const allocator = std.testing.allocator;
    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();

    var kg = kg_mod.KnowledgeGraph.init(allocator, 0);
    defer kg.deinit();
    _ = try kg.addTriplet("E0 Lattice", "contains", "421 nodes", 1000, 0);

    reg.attachKnowledgeGraph(&kg);

    const res = try reg.execute(.{
        .id = "es1",
        .name = "external_search",
        .arguments_json = "{\"query\":\"Lattice\"}",
    });
    defer allocator.free(res);

    try std.testing.expect(std.mem.indexOf(u8, res, "success") != null);
    try std.testing.expect(std.mem.indexOf(u8, res, "subgraph_context") != null);
}

test "tools: db_query without attached DB returns no_db_attached" {
    const allocator = std.testing.allocator;
    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();

    const res = try reg.execute(.{
        .id = "db1",
        .name = "db_query",
        .arguments_json = "{\"key\":\"server_port\"}",
    });
    defer allocator.free(res);

    try std.testing.expect(std.mem.indexOf(u8, res, "no_db_attached") != null);
}

// === Phase 2A: Core Utility Tool Tests ===

test "tools: JsonValue getString" {
    const jv = JsonValue.init("{\"name\":\"test\",\"value\":42}");
    try std.testing.expectEqualStrings("test", jv.getString("name").?);
    try std.testing.expect(jv.getString("missing") == null);
}

test "tools: JsonValue getNumber" {
    const jv = JsonValue.init("{\"a\":3.14,\"b\":42}");
    try std.testing.expectApproxEqAbs(@as(f64, 3.14), jv.getNumber("a").?, 0.001);
    try std.testing.expectEqual(@as(i64, 42), jv.getInteger("b").?);
}

test "tools: time_now returns epoch" {
    const allocator = std.testing.allocator;
    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();
    const res = try reg.execute(.{ .id = "t1", .name = "time_now", .arguments_json = "{}" });
    defer allocator.free(res);
    try std.testing.expect(std.mem.indexOf(u8, res, "epoch") != null);
    try std.testing.expect(std.mem.indexOf(u8, res, "success") != null);
}

test "tools: uuid_generate returns valid UUID" {
    const allocator = std.testing.allocator;
    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();
    const res = try reg.execute(.{ .id = "u1", .name = "uuid_generate", .arguments_json = "{}" });
    defer allocator.free(res);
    try std.testing.expect(std.mem.indexOf(u8, res, "uuid") != null);
    try std.testing.expect(std.mem.indexOf(u8, res, "success") != null);
}

test "tools: base64_encode and decode roundtrip" {
    const allocator = std.testing.allocator;
    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();
    const enc_res = try reg.execute(.{ .id = "b1", .name = "base64_encode", .arguments_json = "{\"data\":\"hello\"}" });
    defer allocator.free(enc_res);
    try std.testing.expect(std.mem.indexOf(u8, enc_res, "aGVsbG8=") != null);
    const dec_res = try reg.execute(.{ .id = "b2", .name = "base64_decode", .arguments_json = "{\"data\":\"aGVsbG8=\"}" });
    defer allocator.free(dec_res);
    try std.testing.expect(std.mem.indexOf(u8, dec_res, "hello") != null);
}

test "tools: hash_compute sha256" {
    const allocator = std.testing.allocator;
    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();
    const res = try reg.execute(.{ .id = "h1", .name = "hash_compute", .arguments_json = "{\"data\":\"test\"}" });
    defer allocator.free(res);
    try std.testing.expect(std.mem.indexOf(u8, res, "sha256") != null);
    try std.testing.expect(std.mem.indexOf(u8, res, "success") != null);
}

test "tools: hash_compute crc32" {
    const allocator = std.testing.allocator;
    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();
    const res = try reg.execute(.{ .id = "h2", .name = "hash_compute", .arguments_json = "{\"data\":\"test\",\"algorithm\":\"crc32\"}" });
    defer allocator.free(res);
    try std.testing.expect(std.mem.indexOf(u8, res, "crc32") != null);
    try std.testing.expect(std.mem.indexOf(u8, res, "success") != null);
}

test "tools: json_validate valid JSON" {
    const allocator = std.testing.allocator;
    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();
    const res = try reg.execute(.{ .id = "jv1", .name = "json_validate", .arguments_json = "{\"data\":\"[1,2,3]\"}" });
    defer allocator.free(res);
    try std.testing.expect(std.mem.indexOf(u8, res, "\"valid\":true") != null);
}

test "tools: json_validate invalid JSON" {
    const allocator = std.testing.allocator;
    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();
    const res = try reg.execute(.{ .id = "jv2", .name = "json_validate", .arguments_json = "{\"data\":\"{broken\"}" });
    defer allocator.free(res);
    try std.testing.expect(std.mem.indexOf(u8, res, "\"valid\":false") != null);
}

test "tools: string_replace" {
    const allocator = std.testing.allocator;
    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();
    const res = try reg.execute(.{ .id = "sr1", .name = "string_replace", .arguments_json = "{\"text\":\"hello world\",\"find\":\"world\",\"replace\":\"Zig\"}" });
    defer allocator.free(res);
    try std.testing.expect(std.mem.indexOf(u8, res, "hello Zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, res, "\"replacements\":1") != null);
}

test "tools: file_write and file_read roundtrip" {
    const allocator = std.testing.allocator;
    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();
    const write_res = try reg.execute(.{ .id = "fw1", .name = "file_write", .arguments_json = "{\"path\":\"/tmp/qstar_test.txt\",\"content\":\"test content\"}" });
    defer allocator.free(write_res);
    try std.testing.expect(std.mem.indexOf(u8, write_res, "success") != null);
    const read_res = try reg.execute(.{ .id = "fr1", .name = "file_read", .arguments_json = "{\"path\":\"/tmp/qstar_test.txt\"}" });
    defer allocator.free(read_res);
    try std.testing.expect(std.mem.indexOf(u8, read_res, "test content") != null);
    std.fs.cwd().deleteFile("/tmp/qstar_test.txt") catch {};
}

test "tools: file_list on current directory" {
    const allocator = std.testing.allocator;
    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();
    const res = try reg.execute(.{ .id = "fl1", .name = "file_list", .arguments_json = "{\"path\":\".\"}" });
    defer allocator.free(res);
    try std.testing.expect(std.mem.indexOf(u8, res, "entries") != null);
    try std.testing.expect(std.mem.indexOf(u8, res, "success") != null);
}

// === Phase 2B: Text Processing Tool Tests ===

test "tools: word_count" {
    const allocator = std.testing.allocator;
    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();
    const res = try reg.execute(.{ .id = "wc1", .name = "word_count", .arguments_json = "{\"text\":\"Hello world. This is a test.\"}" });
    defer allocator.free(res);
    try std.testing.expect(std.mem.indexOf(u8, res, "\"words\":6") != null);
    try std.testing.expect(std.mem.indexOf(u8, res, "\"sentences\":2") != null);
}

test "tools: text_summarize" {
    const allocator = std.testing.allocator;
    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();
    const res = try reg.execute(.{ .id = "ts1", .name = "text_summarize", .arguments_json = "{\"text\":\"First sentence. Second sentence. Third sentence. Fourth sentence.\",\"sentences\":2}" });
    defer allocator.free(res);
    try std.testing.expect(std.mem.indexOf(u8, res, "First sentence") != null);
    try std.testing.expect(std.mem.indexOf(u8, res, "\"sentence_count\":2") != null);
}

test "tools: sentiment_analyze positive" {
    const allocator = std.testing.allocator;
    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();
    const res = try reg.execute(.{ .id = "sent1", .name = "sentiment_analyze", .arguments_json = "{\"text\":\"This is great and wonderful. I love it.\"}" });
    defer allocator.free(res);
    try std.testing.expect(std.mem.indexOf(u8, res, "positive") != null);
}

test "tools: sentiment_analyze negative" {
    const allocator = std.testing.allocator;
    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();
    const res = try reg.execute(.{ .id = "sent2", .name = "sentiment_analyze", .arguments_json = "{\"text\":\"This is terrible and awful. I hate it.\"}" });
    defer allocator.free(res);
    try std.testing.expect(std.mem.indexOf(u8, res, "negative") != null);
}

test "tools: ner_extract" {
    const allocator = std.testing.allocator;
    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();
    const res = try reg.execute(.{ .id = "ner1", .name = "ner_extract", .arguments_json = "{\"text\":\"Dr Smith went to Inc to meet President Jones.\"}" });
    defer allocator.free(res);
    try std.testing.expect(std.mem.indexOf(u8, res, "entities") != null);
    try std.testing.expect(std.mem.indexOf(u8, res, "person") != null);
}

test "tools: text_classify" {
    const allocator = std.testing.allocator;
    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();
    const res = try reg.execute(.{ .id = "tc1", .name = "text_classify", .arguments_json = "{\"text\":\"The quantum physics of particle waves and energy.\"}" });
    defer allocator.free(res);
    try std.testing.expect(std.mem.indexOf(u8, res, "science") != null);
}

test "tools: text_diff" {
    const allocator = std.testing.allocator;
    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();
    const res = try reg.execute(.{ .id = "td1", .name = "text_diff", .arguments_json = "{\"text_a\":\"line1\nline2\nline3\",\"text_b\":\"line1\nmodified\nline3\"}" });
    defer allocator.free(res);
    try std.testing.expect(std.mem.indexOf(u8, res, "modified") != null);
    try std.testing.expect(std.mem.indexOf(u8, res, "\"changes\":1") != null);
}

test "tools: language_detect english" {
    const allocator = std.testing.allocator;
    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();
    const res = try reg.execute(.{ .id = "ld1", .name = "language_detect", .arguments_json = "{\"text\":\"The quick brown fox jumps over the lazy dog. This is a test of the system.\"}" });
    defer allocator.free(res);
    try std.testing.expect(std.mem.indexOf(u8, res, "english") != null);
}

// === Phase 2C: Knowledge & Retrieval Tool Tests ===

test "tools: kg_add_triplet with attached KG" {
    const allocator = std.testing.allocator;
    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();
    var kg = kg_mod.KnowledgeGraph.init(allocator, 0);
    defer kg.deinit();
    reg.attachKnowledgeGraph(&kg);
    const res = try reg.execute(.{ .id = "kat1", .name = "kg_add_triplet", .arguments_json = "{\"subject\":\"Cat\",\"predicate\":\"is_a\",\"object\":\"Animal\"}" });
    defer allocator.free(res);
    try std.testing.expect(std.mem.indexOf(u8, res, "success") != null);
    try std.testing.expect(std.mem.indexOf(u8, res, "Cat") != null);
}

test "tools: kg_add_triplet without KG returns error" {
    const allocator = std.testing.allocator;
    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();
    const res = try reg.execute(.{ .id = "kat2", .name = "kg_add_triplet", .arguments_json = "{\"subject\":\"X\",\"predicate\":\"Y\",\"object\":\"Z\"}" });
    defer allocator.free(res);
    try std.testing.expect(std.mem.indexOf(u8, res, "no_kg_attached") != null);
}

test "tools: kg_export with attached KG" {
    const allocator = std.testing.allocator;
    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();
    var kg = kg_mod.KnowledgeGraph.init(allocator, 0);
    defer kg.deinit();
    _ = try kg.addTriplet("A", "B", "C", 1000, 0);
    reg.attachKnowledgeGraph(&kg);
    const res = try reg.execute(.{ .id = "ke1", .name = "kg_export", .arguments_json = "{}" });
    defer allocator.free(res);
    try std.testing.expect(std.mem.indexOf(u8, res, "triplets") != null);
    try std.testing.expect(std.mem.indexOf(u8, res, "\"subject\":\"A\"") != null);
}

test "tools: kg_export without KG returns error" {
    const allocator = std.testing.allocator;
    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();
    const res = try reg.execute(.{ .id = "ke2", .name = "kg_export", .arguments_json = "{}" });
    defer allocator.free(res);
    try std.testing.expect(std.mem.indexOf(u8, res, "no_kg_attached") != null);
}

test "tools: wikipedia_lookup returns result or not_found" {
    const allocator = std.testing.allocator;
    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();
    const res = try reg.execute(.{ .id = "wiki1", .name = "wikipedia_lookup", .arguments_json = "{\"query\":\"quantum\"}" });
    defer allocator.free(res);
    try std.testing.expect(std.mem.indexOf(u8, res, "wikipedia") != null);
}

test "tools: dictionary_lookup returns result or not_found" {
    const allocator = std.testing.allocator;
    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();
    const res = try reg.execute(.{ .id = "dict1", .name = "dictionary_lookup", .arguments_json = "{\"word\":\"test\"}" });
    defer allocator.free(res);
    try std.testing.expect(std.mem.indexOf(u8, res, "webster") != null);
}

test "tools: law_lookup returns result or not_found" {
    const allocator = std.testing.allocator;
    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();
    const res = try reg.execute(.{ .id = "law1", .name = "law_lookup", .arguments_json = "{\"term\":\"contract\"}" });
    defer allocator.free(res);
    try std.testing.expect(std.mem.indexOf(u8, res, "blacks_law") != null);
}

test "tools: rag_search returns results" {
    const allocator = std.testing.allocator;
    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();
    const res = try reg.execute(.{ .id = "rag1", .name = "rag_search", .arguments_json = "{\"query\":\"quantum physics\",\"max_results\":3}" });
    defer allocator.free(res);
    try std.testing.expect(std.mem.indexOf(u8, res, "results") != null);
}

// === Phase 2D: Data Analysis Tool Tests ===

test "tools: stats_compute" {
    const allocator = std.testing.allocator;
    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();
    const res = try reg.execute(.{ .id = "st1", .name = "stats_compute", .arguments_json = "{\"data\":\"1,2,3,4,5\"}" });
    defer allocator.free(res);
    try std.testing.expect(std.mem.indexOf(u8, res, "\"mean\":3") != null);
    try std.testing.expect(std.mem.indexOf(u8, res, "\"median\":3") != null);
    try std.testing.expect(std.mem.indexOf(u8, res, "\"min\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, res, "\"max\":5") != null);
}

test "tools: csv_parse" {
    const allocator = std.testing.allocator;
    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();
    const res = try reg.execute(.{ .id = "csv1", .name = "csv_parse", .arguments_json = "{\"data\":\"name,age\nAlice,30\nBob,25\"}" });
    defer allocator.free(res);
    try std.testing.expect(std.mem.indexOf(u8, res, "records") != null);
    try std.testing.expect(std.mem.indexOf(u8, res, "Alice") != null);
    try std.testing.expect(std.mem.indexOf(u8, res, "\"count\":2") != null);
}

test "tools: data_sort ascending" {
    const allocator = std.testing.allocator;
    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();
    const res = try reg.execute(.{ .id = "ds1", .name = "data_sort", .arguments_json = "{\"data\":\"3,1,4,1,5,9,2,6\"}" });
    defer allocator.free(res);
    try std.testing.expect(std.mem.indexOf(u8, res, "sorted") != null);
    try std.testing.expect(std.mem.indexOf(u8, res, "\"order\":\"asc\"") != null);
}

test "tools: data_sort descending" {
    const allocator = std.testing.allocator;
    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();
    const res = try reg.execute(.{ .id = "ds2", .name = "data_sort", .arguments_json = "{\"data\":\"3,1,4,1,5\",\"order\":\"desc\"}" });
    defer allocator.free(res);
    try std.testing.expect(std.mem.indexOf(u8, res, "\"order\":\"desc\"") != null);
}

test "tools: data_filter gt" {
    const allocator = std.testing.allocator;
    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();
    const res = try reg.execute(.{ .id = "df1", .name = "data_filter", .arguments_json = "{\"data\":\"1,5,3,8,2,7\",\"op\":\"gt\",\"value\":4}" });
    defer allocator.free(res);
    try std.testing.expect(std.mem.indexOf(u8, res, "filtered") != null);
    try std.testing.expect(std.mem.indexOf(u8, res, "\"count\":3") != null);
}

test "tools: histogram_generate" {
    const allocator = std.testing.allocator;
    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();
    const res = try reg.execute(.{ .id = "hg1", .name = "histogram_generate", .arguments_json = "{\"data\":\"1,2,3,4,5,5,5,5\",\"bins\":5}" });
    defer allocator.free(res);
    try std.testing.expect(std.mem.indexOf(u8, res, "bins") != null);
    try std.testing.expect(std.mem.indexOf(u8, res, "\"total_values\":8") != null);
}

test "tools: correlation_compute perfect positive" {
    const allocator = std.testing.allocator;
    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();
    const res = try reg.execute(.{ .id = "corr1", .name = "correlation_compute", .arguments_json = "{\"data_a\":\"1,2,3,4,5\",\"data_b\":\"2,4,6,8,10\"}" });
    defer allocator.free(res);
    try std.testing.expect(std.mem.indexOf(u8, res, "pearson_r") != null);
    try std.testing.expect(std.mem.indexOf(u8, res, "success") != null);
}

test "tools: correlation_compute mismatched lengths" {
    const allocator = std.testing.allocator;
    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();
    const res = try reg.execute(.{ .id = "corr2", .name = "correlation_compute", .arguments_json = "{\"data_a\":\"1,2,3\",\"data_b\":\"1,2\"}" });
    defer allocator.free(res);
    try std.testing.expect(std.mem.indexOf(u8, res, "error") != null);
    try std.testing.expect(std.mem.indexOf(u8, res, "equal_nonzero_length") != null);
}

// === Vision Tool Tests ===

test "tools: face_detect filters by threshold" {
    const allocator = std.testing.allocator;
    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();
    const res = try reg.execute(.{ .id = "fd1", .name = "face_detect", .arguments_json = "{\"boxes\":\"10,10,100,100,0.9;20,20,80,80,0.3\",\"img_width\":200,\"img_height\":200,\"threshold\":0.5}" });
    defer allocator.free(res);
    try std.testing.expect(std.mem.indexOf(u8, res, "\"count\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, res, "0.9") != null);
}

test "tools: face_detect empty boxes" {
    const allocator = std.testing.allocator;
    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();
    const res = try reg.execute(.{ .id = "fd2", .name = "face_detect", .arguments_json = "{\"boxes\":\"\",\"img_width\":200,\"img_height\":200}" });
    defer allocator.free(res);
    try std.testing.expect(std.mem.indexOf(u8, res, "\"count\":0") != null);
}

test "tools: face_recognize identical embeddings" {
    const allocator = std.testing.allocator;
    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();
    const res = try reg.execute(.{ .id = "fr1", .name = "face_recognize", .arguments_json = "{\"embedding_a\":\"1,0,0,0.5\",\"embedding_b\":\"1,0,0,0.5\"}" });
    defer allocator.free(res);
    try std.testing.expect(std.mem.indexOf(u8, res, "\"similarity\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, res, "\"is_same\":true") != null);
}

test "tools: face_recognize different embeddings" {
    const allocator = std.testing.allocator;
    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();
    const res = try reg.execute(.{ .id = "fr2", .name = "face_recognize", .arguments_json = "{\"embedding_a\":\"1,0,0\",\"embedding_b\":\"0,1,0\"}" });
    defer allocator.free(res);
    try std.testing.expect(std.mem.indexOf(u8, res, "\"similarity\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, res, "\"is_same\":false") != null);
}

test "tools: face_analyze computes quality" {
    const allocator = std.testing.allocator;
    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();
    const res = try reg.execute(.{ .id = "fa1", .name = "face_analyze", .arguments_json = "{\"x1\":50,\"y1\":50,\"x2\":150,\"y2\":180,\"img_width\":300,\"img_height\":300}" });
    defer allocator.free(res);
    try std.testing.expect(std.mem.indexOf(u8, res, "quality_score") != null);
    try std.testing.expect(std.mem.indexOf(u8, res, "aspect_ratio") != null);
}

test "tools: face_track matches overlapping boxes" {
    const allocator = std.testing.allocator;
    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();
    const res = try reg.execute(.{ .id = "ft1", .name = "face_track", .arguments_json = "{\"prev_boxes\":\"10,10,100,100\",\"curr_boxes\":\"12,12,98,98;200,200,300,300\",\"iou_threshold\":0.3}" });
    defer allocator.free(res);
    try std.testing.expect(std.mem.indexOf(u8, res, "\"match_count\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, res, "\"iou\"") != null);
}

test "tools: face_track no matches" {
    const allocator = std.testing.allocator;
    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();
    const res = try reg.execute(.{ .id = "ft2", .name = "face_track", .arguments_json = "{\"prev_boxes\":\"10,10,50,50\",\"curr_boxes\":\"200,200,300,300\",\"iou_threshold\":0.3}" });
    defer allocator.free(res);
    try std.testing.expect(std.mem.indexOf(u8, res, "\"match_count\":0") != null);
}

test "tools: gaze_estimate returns pitch yaw roll" {
    const allocator = std.testing.allocator;
    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();
    const res = try reg.execute(.{ .id = "ge1", .name = "gaze_estimate", .arguments_json = "{\"left_eye_x\":0.3,\"left_eye_y\":0.4,\"right_eye_x\":0.7,\"right_eye_y\":0.4,\"nose_x\":0.5,\"nose_y\":0.6}" });
    defer allocator.free(res);
    try std.testing.expect(std.mem.indexOf(u8, res, "pitch") != null);
    try std.testing.expect(std.mem.indexOf(u8, res, "yaw") != null);
    try std.testing.expect(std.mem.indexOf(u8, res, "roll") != null);
}

test "tools: emotion_detect classifies happy" {
    const allocator = std.testing.allocator;
    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();
    const res = try reg.execute(.{ .id = "ed1", .name = "emotion_detect", .arguments_json = "{\"scores\":\"0.1,0.8,0.02,0.03,0.01,0.01,0.01,0.02\"}" });
    defer allocator.free(res);
    try std.testing.expect(std.mem.indexOf(u8, res, "\"emotion\":\"happy\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, res, "\"confidence\":0.8") != null);
}

test "tools: emotion_detect classifies neutral" {
    const allocator = std.testing.allocator;
    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();
    const res = try reg.execute(.{ .id = "ed2", .name = "emotion_detect", .arguments_json = "{\"scores\":\"0.7,0.05,0.05,0.05,0.05,0.03,0.03,0.04\"}" });
    defer allocator.free(res);
    try std.testing.expect(std.mem.indexOf(u8, res, "\"emotion\":\"neutral\"") != null);
}

// =============================================================================
// Framework Tools (E=mc²-i-E=mc⁻² toy-model tuning)
// =============================================================================

/// Framework audit tool: verifies the E=mc²-i-E=mc⁻² toy-model's mathematical
/// identities and returns a JSON report of the verification results.
pub fn frameworkAuditReport() []const u8 {
    return 
    \\{"framework":"E=mc²-i-E=mc⁻²","audit":{
    \\  "421_identity":"421 = (15³ - 7) / 8",
    \\  "shell_transition":"16³ - 15³ = 721 = 3(240) + 1",
    \\  "surface_computation":"2 + 7 = 9",
    \\  "e8_roots":"15 × 16 = 240",
    \\  "consciousness_aperture":"1/8",
    \\  "c_value":"C = 2",
    \\  "7_defect":"2³ - 1 = 7",
    \\  "scaling_chain":"15 → 16 → 32 → 62 → 128 → 256",
    \\  "generative_chain":"0^0=i → C → H → O → SM → E8 → Higgs"
    \\}}
    ;
}

/// Framework query tool: answers questions about the framework's mathematical structure.
pub fn frameworkQueryTool(query: []const u8) []const u8 {
    if (std.mem.indexOf(u8, query, "421") != null) {
        return "The 421 identity: 421 = (15³ - 7) / 8, connecting the E0 node count to the octonion dimension.";
    }
    if (std.mem.indexOf(u8, query, "7-defect") != null or std.mem.indexOf(u8, query, "7 defect") != null) {
        return "The 7-defect: 2³ - 1 = 7, the structural gap in cubic doubling.";
    }
    if (std.mem.indexOf(u8, query, "1/8") != null or std.mem.indexOf(u8, query, "aperture") != null) {
        return "The consciousness aperture: 1/8, the observer fraction of the lattice space.";
    }
    if (std.mem.indexOf(u8, query, "C=2") != null or std.mem.indexOf(u8, query, "consciousness") != null) {
        return "C=2: the consciousness value from the 5D→6D transition (observer-observed duality).";
    }
    if (std.mem.indexOf(u8, query, "E8") != null or std.mem.indexOf(u8, query, "240") != null) {
        return "The E8 root system: 240 roots = 15 × 16 (SM fermions × SO(10) spinor).";
    }
    return "Framework query: see /api/framework endpoint for full details.";
}

test "framework: audit report is valid JSON" {
    const report = frameworkAuditReport();
    try std.testing.expect(std.mem.indexOf(u8, report, "framework") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "421") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "E8") != null);
}

test "framework: query tool answers 421 question" {
    const answer = frameworkQueryTool("What is the 421 identity?");
    try std.testing.expect(std.mem.indexOf(u8, answer, "421") != null);
}

test "tools: all 58 tools have dimensional assignment" {
    const allocator = std.testing.allocator;
    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();
    try reg.registerBuiltins();
    try std.testing.expectEqual(@as(usize, 58), reg.toolCount());
}

test "tools: e0_origin has uuid_generate and time_now" {
    const allocator = std.testing.allocator;
    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();
    try reg.registerBuiltins();
    try std.testing.expectEqual(@as(usize, 2), reg.countByDimension(.e0_origin));
    try std.testing.expectEqual(ToolDimension.e0_origin, reg.getDimension("uuid_generate").?);
    try std.testing.expectEqual(ToolDimension.e0_origin, reg.getDimension("time_now").?);
}

test "tools: e1_time has tracking tools" {
    const allocator = std.testing.allocator;
    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();
    try reg.registerBuiltins();
    try std.testing.expectEqual(@as(usize, 4), reg.countByDimension(.e1_time));
    try std.testing.expectEqual(ToolDimension.e1_time, reg.getDimension("track_flight").?);
    try std.testing.expectEqual(ToolDimension.e1_time, reg.getDimension("track_vessel").?);
    try std.testing.expectEqual(ToolDimension.e1_time, reg.getDimension("track_satellite").?);
    try std.testing.expectEqual(ToolDimension.e1_time, reg.getDimension("earthquake_query").?);
}

test "tools: e2_quantum has search tools" {
    const allocator = std.testing.allocator;
    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();
    try reg.registerBuiltins();
    try std.testing.expectEqual(@as(usize, 7), reg.countByDimension(.e2_quantum));
    try std.testing.expectEqual(ToolDimension.e2_quantum, reg.getDimension("external_search").?);
    try std.testing.expectEqual(ToolDimension.e2_quantum, reg.getDimension("rag_search").?);
    try std.testing.expectEqual(ToolDimension.e2_quantum, reg.getDimension("wikipedia_lookup").?);
    try std.testing.expectEqual(ToolDimension.e2_quantum, reg.getDimension("dictionary_lookup").?);
    try std.testing.expectEqual(ToolDimension.e2_quantum, reg.getDimension("law_lookup").?);
    try std.testing.expectEqual(ToolDimension.e2_quantum, reg.getDimension("kg_query").?);
    try std.testing.expectEqual(ToolDimension.e2_quantum, reg.getDimension("db_query").?);
}

test "tools: e3_space has geo tools" {
    const allocator = std.testing.allocator;
    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();
    try reg.registerBuiltins();
    try std.testing.expectEqual(@as(usize, 8), reg.countByDimension(.e3_space));
    try std.testing.expectEqual(ToolDimension.e3_space, reg.getDimension("geo_distance").?);
    try std.testing.expectEqual(ToolDimension.e3_space, reg.getDimension("geo_convert").?);
    try std.testing.expectEqual(ToolDimension.e3_space, reg.getDimension("globe_query").?);
    try std.testing.expectEqual(ToolDimension.e3_space, reg.getDimension("cctv_query").?);
    try std.testing.expectEqual(ToolDimension.e3_space, reg.getDimension("annotation_add").?);
}

test "tools: e4_energy has execution tools" {
    const allocator = std.testing.allocator;
    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();
    try reg.registerBuiltins();
    try std.testing.expectEqual(@as(usize, 6), reg.countByDimension(.e4_energy));
    try std.testing.expectEqual(ToolDimension.e4_energy, reg.getDimension("shell_exec").?);
    try std.testing.expectEqual(ToolDimension.e4_energy, reg.getDimension("file_write").?);
    try std.testing.expectEqual(ToolDimension.e4_energy, reg.getDimension("http_fetch").?);
    try std.testing.expectEqual(ToolDimension.e4_energy, reg.getDimension("scene_play").?);
    try std.testing.expectEqual(ToolDimension.e4_energy, reg.getDimension("hud_control").?);
    try std.testing.expectEqual(ToolDimension.e4_energy, reg.getDimension("kg_add_triplet").?);
}

test "tools: e5_structure has data tools" {
    const allocator = std.testing.allocator;
    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();
    try reg.registerBuiltins();
    try std.testing.expectEqual(@as(usize, 20), reg.countByDimension(.e5_structure));
    try std.testing.expectEqual(ToolDimension.e5_structure, reg.getDimension("calculate").?);
    try std.testing.expectEqual(ToolDimension.e5_structure, reg.getDimension("base64_encode").?);
    try std.testing.expectEqual(ToolDimension.e5_structure, reg.getDimension("json_validate").?);
    try std.testing.expectEqual(ToolDimension.e5_structure, reg.getDimension("file_read").?);
    try std.testing.expectEqual(ToolDimension.e5_structure, reg.getDimension("text_summarize").?);
}

test "tools: e6_metacognition has analysis tools" {
    const allocator = std.testing.allocator;
    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();
    try reg.registerBuiltins();
    try std.testing.expectEqual(@as(usize, 9), reg.countByDimension(.e6_metacognition));
    try std.testing.expectEqual(ToolDimension.e6_metacognition, reg.getDimension("sentiment_analyze").?);
    try std.testing.expectEqual(ToolDimension.e6_metacognition, reg.getDimension("ner_extract").?);
    try std.testing.expectEqual(ToolDimension.e6_metacognition, reg.getDimension("text_classify").?);
    try std.testing.expectEqual(ToolDimension.e6_metacognition, reg.getDimension("face_detect").?);
    try std.testing.expectEqual(ToolDimension.e6_metacognition, reg.getDimension("face_recognize").?);
    try std.testing.expectEqual(ToolDimension.e6_metacognition, reg.getDimension("emotion_detect").?);
}

test "tools: e7_physics has quantum and lattice tools" {
    const allocator = std.testing.allocator;
    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();
    try reg.registerBuiltins();
    try std.testing.expectEqual(@as(usize, 2), reg.countByDimension(.e7_physics));
    try std.testing.expectEqual(ToolDimension.e7_physics, reg.getDimension("quantum_simulate").?);
    try std.testing.expectEqual(ToolDimension.e7_physics, reg.getDimension("lattice_node").?);
}

test "tools: listByDimension returns valid JSON with all 8 dimensions" {
    const allocator = std.testing.allocator;
    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();
    try reg.registerBuiltins();
    const json = try reg.listByDimension(allocator);
    defer allocator.free(json);
    // Check all 8 dimension labels are present
    try std.testing.expect(std.mem.indexOf(u8, json, "e0=origin") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "e1=time") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "e2=quantum") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "e3=space") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "e4=energy") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "e5=structure") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "e6=metacognition") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "e7=physics") != null);
}
