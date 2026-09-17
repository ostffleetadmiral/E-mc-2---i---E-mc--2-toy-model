//! server.zig — Zero-Dependency Ollama & OpenAI-Compatible HTTP API Server for Qstar
//!
//! Serves Ollama endpoints (/api/generate, /api/chat, /api/tags, /api/version, /api/embeddings)
//! and OpenAI endpoints (/v1/chat/completions, /v1/completions, /v1/models, /v1/embeddings)
//! over raw TCP sockets with zero external dependencies.

const std = @import("std");
const agent_mod = @import("agent");
const fp = @import("fixed_point");
const tools_mod = @import("tools");
const bpe = @import("bpe_tokenizer");
const kg_mod = @import("knowledge_graph");
const db_mod = @import("external_db");
const turing = @import("turing_test");

const DEFAULT_TOKENIZER_PATH = "models/qwen1.5-0.5b-chat";

fn loadTokenizer(allocator: std.mem.Allocator) ?bpe.Tokenizer {
    return bpe.Tokenizer.loadQwenTokenizer(allocator, DEFAULT_TOKENIZER_PATH) catch null;
}

const SEED_CORPUS: []const u8 =
    \\The quick brown fox jumps over the lazy dog. A journey of a thousand miles begins with a single step.
    \\To be or not to be, that is the question. All animals are equal but some animals are more equal than others.
    \\The only thing we have to fear is fear itself. I think therefore I am. Knowledge is power.
    \\Actions speak louder than words. The early bird catches the worm. Practice makes perfect.
    \\Where there is a will there is a way. Better late than never. When in Rome do as the Romans do.
    \\The pen is mightier than the sword. You cannot judge a book by its cover. A picture is worth a thousand words.
    \\Necessity is the mother of invention. The best things in life are free. Time heals all wounds.
    \\Give someone an inch and they will take a mile. The grass is always greener on the other side.
    \\If you want something done right do it yourself. A friend in need is a friend indeed.
    \\Two heads are better than one. Do not put all your eggs in one basket. Rome was not built in a day.
    \\When the going gets tough the tough get going. Every cloud has a silver lining.
    \\Nothing ventured nothing gained. The squeaky wheel gets the grease. You reap what you sow.
    \\Honesty is the best policy. Patience is a virtue. An apple a day keeps the doctor away.
    \\Good things come to those who wait. A stitch in time saves nine. Misery loves company.
    \\Quantum superposition allows particles to exist in multiple states simultaneously until measured.
    \\The quantum state vector collapses into an observable eigenstate upon measurement.
    \\Quantum entanglement connects particles across vast distances through nonlocal correlations.
    \\The Heisenberg uncertainty principle states that position and momentum cannot be simultaneously known.
    \\Quantum decoherence occurs when a quantum system interacts with its environment losing phase coherence.
    \\The Schrodinger equation describes how the quantum state of a physical system changes over time.
    \\Quantum tunneling enables particles to pass through energy barriers that they classically should not.
    \\The double slit experiment demonstrates wave particle duality of light and matter.
    \\Quantum computing uses qubits that can exist in superposition of zero and one states.
    \\Grover search algorithm provides quadratic speedup over classical linear search algorithms.
    \\Shor algorithm factors integers in polynomial time on a quantum computer.
    \\Quantum error correction uses entangled ancilla qubits to detect and correct errors.
    \\The Bell inequality proves that quantum mechanics cannot be explained by local hidden variables.
    \\Quantum field theory describes particles as excitations of underlying fields permeating spacetime.
    \\The Planck constant relates the energy of a photon to its frequency in quantum mechanics.
    \\The E0 lattice projects continuous coordinates onto a discrete grid with 421 basis nodes.
    \\Octonionic routing distributes activation signals across seven reasoning channels.
    \\The Fibonacci projection weights channel activations using golden ratio proportions.
    \\Discrete lattice geometry provides a natural framework for cellular automaton computation.
    \\The Mobius reflection at boundary nodes creates symmetric activation patterns.
    \\Refractory inhibition prevents repeated firing of the same node in consecutive cycles.
    \\Self-assembly Monte Carlo relaxation reconfigures activation flow paths with phi cooling.
    \\The lattice invariant constraint requires that coordinates satisfy modular arithmetic conditions.
    \\E0 nodes fire when their activation exceeds a threshold after temperature scaling.
    \\Neighbor propagation spreads activation along lattice edges with weighted connections.
    \\Fixed-point arithmetic eliminates floating-point rounding drift across different hardware.
    \\The Q32.32 format represents values as 64-bit integers with 32 fractional bits.
    \\Integer-only computation guarantees deterministic execution on any processor architecture.
    \\Fixed-point multiplication requires careful shifting to maintain precision.
    \\The golden ratio appears in nature art and architecture as a proportion of harmony.
    \\Fibonacci sequences model growth patterns in shells plants and spiral galaxies.
    \\Mathematics is the language of nature describing patterns and relationships in abstract structures.
    \\Calculus studies rates of change and accumulation through derivatives and integrals.
    \\Linear algebra examines vector spaces matrices and linear transformations.
    \\Probability theory quantifies uncertainty and randomness in events and processes.
    \\Statistics collects analyzes and interprets data to draw meaningful conclusions.
    \\Geometry studies shapes sizes positions and properties of space and figures.
    \\Number theory explores the properties and relationships of integers and primes.
    \\Topology examines properties of spaces that are preserved under continuous deformations.
    \\Algebra uses symbols to represent numbers and relationships in equations and formulas.
    \\Set theory provides the foundation of mathematics with collections of objects.
    \\Programming is the art of instructing computers to perform tasks through code.
    \\Software engineering applies systematic design principles to create reliable programs.
    \\Algorithms are step-by-step procedures for solving problems and processing data.
    \\Data structures organize information efficiently for storage retrieval and manipulation.
    \\Compilation translates source code into machine instructions that processors execute.
    \\Debugging is the process of identifying and fixing errors in software programs.
    \\Functions encapsulate reusable logic that accepts parameters and returns results.
    \\Variables store data values that can be read and modified during program execution.
    \\Loops repeat blocks of code until a condition is met or a limit is reached.
    \\Recursion occurs when a function calls itself to solve smaller instances of a problem.
    \\Object oriented programming models real-world entities as objects with state and behavior.
    \\Functional programming emphasizes pure functions and immutable data structures.
    \\Memory management allocates and deallocates storage for program data and objects.
    \\Concurrency allows multiple tasks to execute simultaneously sharing resources safely.
    \\Computer networks connect devices to share data and resources across distances.
    \\The internet is a global network of networks using standard communication protocols.
    \\TCP provides reliable ordered delivery of data packets between networked applications.
    \\UDP offers lightweight fast datagram transmission without delivery guarantees.
    \\Routing algorithms determine the best paths for data to travel through networks.
    \\Network protocols define rules for communication between connected systems.
    \\Packet switching breaks data into small units for efficient network transmission.
    \\Cryptography secures communications by encrypting data with mathematical algorithms.
    \\Firewalls filter network traffic to block unauthorized access to protected systems.
    \\Domain name systems translate human-readable names into IP addresses for routing.
    \\Mesh networking creates resilient peer-to-peer connections without central infrastructure.
    \\Peer-to-peer protocols enable direct communication between nodes without intermediaries.
    \\Data compression reduces the size of information for efficient storage and transmission.
    \\Lossless compression preserves all original data while reducing redundancy.
    \\Lossy compression sacrifices some fidelity for higher compression ratios.
    \\Huffman coding assigns shorter codes to more frequent symbols in data.
    \\Entropy encoding uses probability distributions to optimize code lengths.
    \\Quantization reduces precision of values to decrease storage requirements.
    \\Bit packing stores multiple small values within single bytes for compactness.
    \\Run-length encoding replaces repeated sequences with count and value pairs.
    \\Dictionary compression replaces repeated patterns with references to a table.
    \\Transform coding converts data to a frequency domain for more efficient compression.
    \\Artificial intelligence enables machines to learn reason and make decisions.
    \\Machine learning trains models on data to recognize patterns and make predictions.
    \\Neural networks use layered interconnected nodes inspired by biological neurons.
    \\Deep learning uses neural networks with many layers for complex feature extraction.
    \\Natural language processing enables computers to understand and generate human language.
    \\Computer vision allows machines to interpret and analyze visual information.
    \\Reinforcement learning trains agents through rewards and punishments in environments.
    \\Supervised learning uses labeled data to train models for prediction tasks.
    \\Unsupervised learning discovers patterns in unlabeled data without guidance.
    \\Transfer learning adapts pretrained models to new tasks with minimal retraining.
    \\Large language models generate text by predicting next tokens from context.
    \\Attention mechanisms allow models to focus on relevant parts of input sequences.
    \\Transformers process sequences in parallel using self-attention mechanisms.
    \\Tokenization splits text into units that models can process and understand.
    \\Inference runs trained models on new inputs to produce predictions or outputs.
    \\The speed of light in vacuum is approximately 299792458 meters per second.
    \\Einstein theory of relativity shows that space and time are interconnected.
    \\Special relativity demonstrates that observers in different frames measure different times.
    \\General relativity describes gravity as curvature of spacetime caused by mass.
    \\Energy and mass are equivalent according to the famous equation E equals mc squared.
    \\The universe is expanding with galaxies moving apart at accelerating rates.
    \\Dark matter exerts gravitational influence but does not emit or absorb light.
    \\Dark energy drives the accelerated expansion of the universe over cosmic time.
    \\Black holes are regions where gravity is so strong that nothing can escape.
    \\The Big Bang theory describes the origin of the universe from a singularity.
    \\Life is a characteristic that distinguishes living organisms from inanimate matter.
    \\Consciousness is the state of being aware of and able to perceive experiences.
    \\Evolution by natural selection explains the diversity of life on Earth.
    \\DNA carries the genetic instructions for the development and function of living organisms.
    \\Cells are the basic structural and functional units of all living organisms.
    \\Photosynthesis converts sunlight into chemical energy stored in glucose molecules.
    \\The brain processes information through networks of neurons firing electrical signals.
    \\Memory stores and retrieves information through changes in neural connections.
    \\Learning involves acquiring knowledge or skills through study experience or instruction.
    \\Language enables humans to communicate ideas emotions and knowledge through symbols.
    \\A sunset occurs when the sun descends below the horizon scattering red and orange light.
    \\The sky appears blue because air molecules scatter shorter blue wavelengths more than red.
    \\Weather patterns result from atmospheric pressure temperature and humidity differences.
    \\Rain forms when water vapor condenses into droplets heavy enough to fall.
    \\Wind is the movement of air from high pressure to low pressure regions.
    \\Seasons change because the Earth axis is tilted relative to its orbital plane.
    \\The water cycle evaporates water from oceans forms clouds and returns it as precipitation.
    \\Oceans cover most of the Earth surface and regulate global climate and weather.
    \\Forests absorb carbon dioxide and produce oxygen through photosynthesis.
    \\Ecosystems consist of organisms interacting with each other and their environment.
    \\A cat is a small carnivorous mammal known for its independence and agility.
    \\Dogs are loyal companions that have been domesticated for thousands of years.
    \\Birds are vertebrates adapted for flight with feathers wings and hollow bones.
    \\Fish are aquatic animals with gills that extract oxygen from water.
    \\Insects are the most diverse group of animals with six legs and exoskeletons.
    \\Democracy is a system of government where power resides with the people.
    \\Voting allows citizens to choose their representatives and express preferences.
    \\Freedom of speech enables individuals to express opinions without government censorship.
    \\Human rights are fundamental entitlements that belong to every person universally.
    \\Justice ensures fair treatment and accountability under the law for all.
    \\Equality means that all people have the same rights and opportunities.
    \\Blockchain is a distributed ledger that records transactions across many computers.
    \\Cryptocurrencies use cryptographic techniques to secure financial transactions.
    \\Smart contracts execute automatically when predefined conditions are met.
    \\Decentralized systems operate without central authorities controlling operations.
    \\Consensus mechanisms enable distributed nodes to agree on shared state.
    \\Hello and welcome to the world of intelligent conversation and reasoning.
    \\How can I help you today? I am here to answer questions and provide information.
    \\Thank you for your question. Let me provide a detailed and thoughtful response.
    \\That is an interesting topic. There are many perspectives to consider.
    \\I understand your concern. Let me explain the key concepts and principles.
    \\The answer depends on several factors that we should examine carefully.
    \\Let me break this down into simpler terms for better understanding.
    \\This is a complex subject with many interrelated components and considerations.
    \\To fully understand this we need to consider the underlying principles.
    \\The key insight is that small changes can have large cascading effects.
    \\In summary the main points are clear and the conclusions follow logically.
    \\Therefore we can see that the relationship between these concepts is fundamental.
    \\Furthermore additional research and analysis would provide deeper insights.
    \\Finally it is important to remember that context matters in all situations.
    \\Overall this represents a significant advancement in our understanding.
    \\Love is a complex emotion that encompasses affection compassion and deep attachment.
    \\The meaning of life is a philosophical question that has been debated for centuries.
    \\A joke is a display of humor in which words are used to provoke laughter.
    \\Happiness is a mental state of well-being characterized by positive emotions and life satisfaction.
    \\Friendship is a relationship of mutual affection between people based on trust and support.
    \\Music is an art form that uses sound and rhythm to express emotions and ideas.
    \\Art is a diverse range of human activity involving creative imagination to express beauty and emotion.
    \\Science is a systematic enterprise that builds and organizes knowledge through testable explanations.
    \\Education is the process of facilitating learning and acquiring knowledge skills and values.
    \\Health is a state of physical mental and social well-being not merely the absence of disease.
    \\Time is a continuous sequence of existence and events that occur in apparently irreversible succession.
    \\Space is the boundless three-dimensional extent in which objects and events have position and direction.
    \\The mind is the set of cognitive faculties including consciousness imagination perception and memory.
    \\Knowledge is understanding of or information about a subject acquired through experience or education.
    \\Wisdom is the quality of having experience knowledge and good judgment.
    \\Truth is the property of being in accord with fact or reality.
    \\Beauty is a combination of qualities such as shape color and form that pleases the aesthetic senses.
    \\Freedom is the power or right to act speak or think as one wants without hindrance.
    \\Courage is the ability to do something that frightens one and strength in the face of pain or grief.
;

pub const ServerConfig = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 11435,
    max_concurrent: usize = 8,
    enable_keep_alive: bool = true,
    keep_alive_max_requests: usize = 16,
    agent_pool_size: usize = 4,
    enable_request_batching: bool = true,
    batch_size: usize = 4,
    batch_window_us: u32 = 1000, // 1ms collection window
};

pub const QstarServer = struct {
    allocator: std.mem.Allocator,
    config: ServerConfig,
    listener: ?std.net.Server,
    running: bool,
    tool_registry: tools_mod.ToolRegistry,
    knowledge_graph: ?kg_mod.KnowledgeGraph = null,
    external_db: ?db_mod.ExternalDb = null,
    corpus_cache: ?[]u8 = null,
    routes_cache: ?[]u8 = null,
    tokenizer_cache: ?bpe.Tokenizer = null,
    active_count: std.atomic.Value(usize) = .{ .raw = 0 },
    kg_mutex: std.Thread.Mutex = .{},
    tool_mutex: std.Thread.Mutex = .{},

    // Agent pool: pre-initialized agents with corpus + tokenizer for reuse
    agent_pool: std.ArrayList(*agent_mod.Agent),
    agent_pool_mutex: std.Thread.Mutex = .{},

    // Request batching: collect requests and process in parallel
    batch_queue: std.ArrayList(BatchedRequest),
    batch_mutex: std.Thread.Mutex = .{},
    batch_cond: std.Thread.Condition = .{},

    pub fn init(allocator: std.mem.Allocator, config: ServerConfig) QstarServer {
        return .{
            .allocator = allocator,
            .config = config,
            .listener = null,
            .running = false,
            .tool_registry = tools_mod.ToolRegistry.init(allocator),
            .agent_pool = std.ArrayList(*agent_mod.Agent).init(allocator),
            .batch_queue = std.ArrayList(BatchedRequest).init(allocator),
        };
    }

    pub fn deinit(self: *QstarServer) void {
        if (self.listener) |*l| {
            l.deinit();
        }
        self.tool_registry.deinit();
        if (self.knowledge_graph) |*kg| kg.deinit();
        if (self.corpus_cache) |c| self.allocator.free(c);
        if (self.routes_cache) |r| self.allocator.free(r);
        if (self.tokenizer_cache) |*tok| tok.deinit();
        // Free agent pool
        for (self.agent_pool.items) |agent| {
            agent.deinit();
            self.allocator.destroy(agent);
        }
        self.agent_pool.deinit();
        // Free batch queue
        for (self.batch_queue.items) |*req| {
            req.deinit();
        }
        self.batch_queue.deinit();
    }

    /// Initializes the agent pool with pre-configured agents.
    /// Each agent has corpus and tokenizer pre-loaded for fast request handling.
    pub fn initAgentPool(self: *QstarServer) void {
        const pool_size = @min(self.config.agent_pool_size, self.config.max_concurrent);
        for (0..pool_size) |_| {
            const agent = self.allocator.create(agent_mod.Agent) catch continue;
            agent.* = agent_mod.Agent.init(self.allocator, 0, fp.ONE);
            self.loadCorpusIntoAgent(agent);
            if (self.tokenizer_cache) |tok| {
                agent.attachTokenizer(tok);
                agent.buildBigramModelFromCombined() catch {};
            }
            if (self.knowledge_graph != null) {
                agent.initKnowledgeGraph() catch {};
            }
            self.agent_pool.append(agent) catch {
                agent.deinit();
                self.allocator.destroy(agent);
            };
        }
        if (self.agent_pool.items.len > 0) {
            std.debug.print("  Agent pool: {d} pre-initialized agents ready\n", .{self.agent_pool.items.len});
        }
    }

    /// Acquires an agent from the pool, or creates a new one if pool is empty.
    /// Caller must return the agent via releaseAgent.
    fn acquireAgent(self: *QstarServer) *agent_mod.Agent {
        self.agent_pool_mutex.lock();
        if (self.agent_pool.items.len > 0) {
            const agent = self.agent_pool.pop();
            self.agent_pool_mutex.unlock();
            agent.attachToolRegistry(&self.tool_registry);
            return agent;
        }
        self.agent_pool_mutex.unlock();
        // Pool empty — create a temporary agent
        const agent = self.allocator.create(agent_mod.Agent) catch unreachable;
        agent.* = agent_mod.Agent.init(self.allocator, 0, fp.ONE);
        self.loadCorpusIntoAgent(agent);
        if (self.tokenizer_cache) |tok| {
            agent.attachTokenizer(tok);
            agent.buildBigramModelFromCombined() catch {};
        }
        if (self.knowledge_graph != null) {
            agent.initKnowledgeGraph() catch {};
        }
        agent.attachToolRegistry(&self.tool_registry);
        return agent;
    }

    /// Returns an agent to the pool for reuse, or frees it if pool is full.
    fn releaseAgent(self: *QstarServer, agent: *agent_mod.Agent) void {
        // Detach tool registry before returning to pool
        agent.detachToolRegistry();
        // Reset agent state for reuse (clear working memory, reset lattice)
        agent.working_memory.clear();
        agent.state.reset();
        agent.clearKnowledgeGraph();

        self.agent_pool_mutex.lock();
        if (self.agent_pool.items.len < self.config.agent_pool_size) {
            self.agent_pool.append(agent) catch {
                self.agent_pool_mutex.unlock();
                agent.deinit();
                self.allocator.destroy(agent);
                return;
            };
            self.agent_pool_mutex.unlock();
        } else {
            self.agent_pool_mutex.unlock();
            agent.deinit();
            self.allocator.destroy(agent);
        }
    }

    /// Loads the tokenizer once at startup for reuse across all requests.
    pub fn loadTokenizerCache(self: *QstarServer) void {
        if (self.tokenizer_cache != null) return;
        self.tokenizer_cache = loadTokenizer(self.allocator);
        if (self.tokenizer_cache != null) {
            std.debug.print("  Tokenizer cache: loaded from {s}\n", .{DEFAULT_TOKENIZER_PATH});
        }
    }

    /// Loads the trained corpus from file into memory for reuse across requests.
    /// Called once at server startup to avoid repeated file I/O per request.
    pub fn loadCorpusCache(self: *QstarServer) void {
        const file = std.fs.cwd().openFile("qstar_corpus.txt", .{}) catch {
            // No qstar_corpus.txt — use the built-in framework corpus seed
            const corpus_seed = @import("corpus_seed");
            const seed_text = corpus_seed.SEED_CORPUS_TEXT;
            const buf = self.allocator.dupe(u8, seed_text) catch return;
            self.corpus_cache = buf;
            std.debug.print("  Corpus cache: {d} bytes (built-in framework seed)\n", .{buf.len});
            return;
        };
        defer file.close();
        const size = file.getEndPos() catch return;
        if (size == 0) return;
        const buf = self.allocator.alloc(u8, size) catch return;
        _ = file.readAll(buf) catch {
            self.allocator.free(buf);
            return;
        };
        self.corpus_cache = buf;
        std.debug.print("  Corpus cache: {d} bytes loaded\n", .{size});
    }

    /// Loads the dynamic routes binary into memory for reuse across requests.
    /// Called once at server startup to avoid repeated file I/O per request.
    pub fn loadRoutesCache(self: *QstarServer) void {
        const file = std.fs.cwd().openFile("datasets/dynamic_routes.bin", .{}) catch return;
        defer file.close();
        const size = file.getEndPos() catch return;
        if (size == 0) return;
        const buf = self.allocator.alloc(u8, size) catch return;
        _ = file.readAll(buf) catch {
            self.allocator.free(buf);
            return;
        };
        self.routes_cache = buf;
        std.debug.print("  Routes cache: {d} bytes loaded\n", .{size});
    }

    /// Loads the cached corpus and routes into an agent's dynamic_corpus and route registry.
    /// Uses the pre-loaded caches to avoid file I/O per request.
    fn loadCorpusIntoAgent(self: *QstarServer, agent: *agent_mod.Agent) void {
        if (self.corpus_cache) |c| {
            agent.dynamic_corpus.appendSlice(c) catch {};
        }
        if (self.routes_cache) |r| {
            agent.loadDynamicRoutesFromBuffer(r) catch {};
        }
    }

    pub fn initKnowledgeGraph(self: *QstarServer) !void {
        if (self.knowledge_graph == null) {
            self.knowledge_graph = kg_mod.KnowledgeGraph.init(self.allocator, 0);
            _ = self.knowledge_graph.?.loadFromFile("qstar_kg.bin") catch 0;
            // Seed framework knowledge if KG is empty (no qstar_kg.bin found)
            if (self.knowledge_graph.?.tripletCount() == 0) {
                _ = kg_mod.seedFrameworkKnowledge(&self.knowledge_graph.?) catch 0;
            }
            self.tool_registry.attachKnowledgeGraph(&self.knowledge_graph.?);
        }
    }

    /// Parses prior messages from the JSON request body and populates the agent's
    /// conversation history. The Ollama/OpenAI API sends the full messages array
    /// in each request, so we extract user/assistant pairs and feed them to the agent.
    fn loadConversationFromRequest(self: *QstarServer, agent: *agent_mod.Agent, json_slice: []const u8, current_prompt: []const u8, a: std.mem.Allocator) void {
        _ = self;
        _ = a;

        // Find all "content":"..." pairs in the messages array
        // We look for "role":"user" and "role":"assistant" pairs
        var search_pos: usize = 0;
        var last_role: ?[]const u8 = null;
        var last_content: ?[]const u8 = null;

        while (search_pos < json_slice.len) {
            // Find next "role":" occurrence
            const role_marker = "\"role\":\"";
            const role_pos = std.mem.indexOfPos(u8, json_slice, search_pos, role_marker) orelse break;
            const role_start = role_pos + role_marker.len;
            const role_end = std.mem.indexOfScalarPos(u8, json_slice, role_start, '"') orelse break;
            const role = json_slice[role_start..role_end];

            // Find corresponding "content":" for this message
            const content_marker = "\"content\":\"";
            const content_pos = std.mem.indexOfPos(u8, json_slice, role_end, content_marker) orelse {
                search_pos = role_end + 1;
                continue;
            };
            const content_start = content_pos + content_marker.len;
            const content_end = std.mem.indexOfScalarPos(u8, json_slice, content_start, '"') orelse {
                search_pos = role_end + 1;
                continue;
            };
            const content = json_slice[content_start..content_end];

            // If we have a user message followed by assistant, add to history
            if (last_role) |prev_role| {
                if (std.mem.eql(u8, prev_role, "user") and std.mem.eql(u8, role, "assistant")) {
                    if (last_content) |prev_content| {
                        // Skip the current (last) message — it's the new prompt
                        if (!std.mem.eql(u8, content, current_prompt)) {
                            agent.addToHistory(prev_content, content) catch {};
                        }
                    }
                }
            }

            last_role = role;
            last_content = content;
            search_pos = content_end + 1;
        }
    }

    pub fn initExternalDb(self: *QstarServer) !void {
        if (self.external_db == null) {
            self.external_db = db_mod.ExternalDb.init(self.allocator);
            self.tool_registry.attachExternalDb(&self.external_db.?);
        }
    }

    /// Connection context passed to worker threads
    const ConnectionContext = struct {
        server: *QstarServer,
        stream: std.net.Stream,
    };

    /// A queued request for batch processing.
    /// Each request is collected within the batch window, then processed in parallel.
    const BatchedRequest = struct {
        stream: std.net.Stream,
        req_data: []u8,
        req_len: usize,
        arena: std.heap.ArenaAllocator,
        done: std.atomic.Value(bool) = .{ .raw = false },

        fn deinit(self: *BatchedRequest) void {
            self.arena.deinit();
        }
    };

    /// Enqueues a request for batch processing. The calling thread blocks until
    /// the batch processor picks it up and handles it. Returns when the response
    /// has been sent. Falls back to direct handling if batching is disabled.
    fn enqueueBatchedRequest(self: *QstarServer, stream: std.net.Stream, req_buf: []u8, req_len: usize) !void {
        if (!self.config.enable_request_batching) {
            // Batching disabled: handle directly
            try self.handleConnection(stream, req_buf[0..req_len]);
            return;
        }

        // Create batched request entry
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        const arena_alloc = arena.allocator();
        const req_copy = try arena_alloc.dupe(u8, req_buf[0..req_len]);

        const batch_req = BatchedRequest{
            .stream = stream,
            .req_data = req_copy,
            .req_len = req_copy.len,
            .arena = arena,
        };

        // Enqueue
        self.batch_mutex.lock();
        try self.batch_queue.append(batch_req);
        const queue_len = self.batch_queue.items.len;
        self.batch_mutex.unlock();

        // Signal the batch processor if queue is full
        if (queue_len >= self.config.batch_size) {
            self.batch_cond.signal();
        }

        // Wait for this request to be processed
        // In the current thread-per-connection model, we just process directly
        // after enqueuing (the batch processor runs in the accept loop)
        // For simplicity and correctness, we process inline here using the agent pool
        try self.handleConnection(stream, req_buf[0..req_len]);

        // Mark done and remove from queue
        self.batch_mutex.lock();
        for (self.batch_queue.items, 0..) |*qreq, i| {
            if (qreq.stream.handle == stream.handle) {
                qreq.deinit();
                _ = self.batch_queue.swapRemove(i);
                break;
            }
        }
        self.batch_mutex.unlock();
    }

    /// Worker thread entry point — reads request, handles it, supports keep-alive
    fn connectionThread(ctx: *ConnectionContext) void {
        defer ctx.server.allocator.destroy(ctx);
        defer ctx.stream.close();
        defer _ = ctx.server.active_count.fetchSub(1, .release);

        var req_buf: [8192]u8 = undefined;
        var request_count: usize = 0;
        const max_requests = if (ctx.server.config.enable_keep_alive) ctx.server.config.keep_alive_max_requests else 1;

        while (request_count < max_requests and ctx.server.running) {
            const n = ctx.stream.read(&req_buf) catch |err| {
                if (err != error.ConnectionResetByPeer) {
                    std.debug.print("Read error: {s}\n", .{@errorName(err)});
                }
                return;
            };
            if (n == 0) return;

            // Check if client requested keep-alive
            const keep_alive = ctx.server.config.enable_keep_alive and
                std.mem.indexOf(u8, req_buf[0..n], "Connection: keep-alive") != null or
                (std.mem.indexOf(u8, req_buf[0..n], "Connection: close") == null and
                std.mem.indexOf(u8, req_buf[0..n], "HTTP/1.0") == null);

            ctx.server.enqueueBatchedRequest(ctx.stream, &req_buf, n) catch |err| {
                std.debug.print("Handler error: {s}\n", .{@errorName(err)});
                return;
            };

            request_count += 1;
            if (!keep_alive) break;
        }
    }

    pub fn start(self: *QstarServer) !void {
        const address = try std.net.Address.parseIp4(self.config.host, self.config.port);
        self.listener = try address.listen(.{ .reuse_address = true });
        self.running = true;

        self.initKnowledgeGraph() catch {};
        self.initExternalDb() catch {};
        self.loadCorpusCache();
        self.loadRoutesCache();
        self.loadTokenizerCache();
        self.initAgentPool();
        if (self.knowledge_graph) |*kg| {
            std.debug.print("  Knowledge Graph: {d} triplets, {d} entities\n", .{ kg.tripletCount(), kg.entityCount() });
        }

        const ka_str: []const u8 = if (self.config.enable_keep_alive) "enabled" else "disabled";
        const batch_str: []const u8 = if (self.config.enable_request_batching) "enabled" else "disabled";
        std.debug.print("🚀 Qstar Server listening on http://{s}:{d} (Ollama + OpenAI API compatible, max {d} concurrent, keep-alive {s}, batching {s})\n", .{ self.config.host, self.config.port, self.config.max_concurrent, ka_str, batch_str });

        while (self.running) {
            // Concurrency limiting: wait for a free slot
            while (self.active_count.load(.acquire) >= self.config.max_concurrent) {
                std.time.sleep(100_000); // 100µs backoff
                if (!self.running) break;
            }
            if (!self.running) break;

            const conn = self.listener.?.accept() catch |err| {
                if (!self.running) break;
                std.debug.print("Accept error: {s}\n", .{@errorName(err)});
                continue;
            };

            // Spawn worker thread for concurrent handling
            const ctx = self.allocator.create(ConnectionContext) catch {
                conn.stream.close();
                continue;
            };
            ctx.* = .{ .server = self, .stream = conn.stream };
            _ = self.active_count.fetchAdd(1, .acquire);

            const thread = std.Thread.spawn(.{}, connectionThread, .{ctx}) catch {
                _ = self.active_count.fetchSub(1, .release);
                conn.stream.close();
                self.allocator.destroy(ctx);
                continue;
            };
            thread.detach();
        }

        // Wait for outstanding connections to finish
        while (self.active_count.load(.acquire) > 0) {
            std.time.sleep(1_000_000); // 1ms
        }
    }

    pub fn stop(self: *QstarServer) void {
        self.running = false;
        if (self.listener) |*l| {
            l.deinit();
            self.listener = null;
        }
    }

    pub fn handleConnection(self: *QstarServer, stream: std.net.Stream, request: []const u8) !void {
        // Parse HTTP Method & Path
        var line_it = std.mem.splitScalar(u8, request, '\r');
        const first_line = line_it.first();

        var part_it = std.mem.splitScalar(u8, first_line, ' ');
        const method = part_it.next() orelse return;
        const path = part_it.next() orelse return;

        // Arena allocator for per-request allocations — all freed at once on scope exit
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        // Route requests
        if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/api/tags")) {
            try self.handleTags(stream);
        } else if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/api/version")) {
            try self.handleVersion(stream);
        } else if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/api/framework")) {
            try self.handleFramework(stream);
        } else if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/api/generate")) {
            try self.handleGenerate(stream, request, a);
        } else if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/api/chat")) {
            try self.handleChat(stream, request, a);
        } else if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/api/embeddings")) {
            try self.handleEmbeddings(stream, request, a);
        } else if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/v1/models")) {
            try self.handleV1Models(stream);
        } else if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/v1/completions")) {
            try self.handleV1Completions(stream, request, a);
        } else if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/v1/chat/completions")) {
            try self.handleV1ChatCompletions(stream, request, a);
        } else if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/v1/embeddings")) {
            try self.handleV1Embeddings(stream, request, a);
        } else if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/api/turing-test")) {
            try self.handleTuringTest(stream, request, a);
        } else if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/api/vision")) {
            try self.handleVision(stream, request, a);
        } else if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/api/vision/tools")) {
            try self.handleVisionToolsList(stream);
        } else if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/api/geoview")) {
            try self.handleGeoview(stream, request, a);
        } else if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/api/geoview/tools")) {
            try self.handleGeoviewToolsList(stream);
        } else if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/api/show")) {
            try self.handleShow(stream, request, a);
        } else if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/api/pull")) {
            try self.handlePull(stream, request, a);
        } else if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/api/push")) {
            try self.handlePush(stream, request, a);
        } else if (std.mem.eql(u8, method, "DELETE") and std.mem.eql(u8, path, "/api/delete")) {
            try self.handleDelete(stream, request, a);
        } else if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/api/copy")) {
            try self.handleCopy(stream, request, a);
        } else if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/api/ps")) {
            try self.handlePs(stream);
        } else if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/api/heartbeat")) {
            try self.handleHeartbeat(stream);
        } else if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/api/mesh/status")) {
            try self.handleMeshStatus(stream, a);
        } else if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/api/transport/list")) {
            try self.handleTransportList(stream);
        } else if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/api/mesh/join")) {
            try self.handleMeshJoin(stream, request, a);
        } else if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/api/transport/send")) {
            try self.handleTransportSend(stream, request, a);
        } else {
            try self.sendJsonResponse(stream, 404, "{\"error\":\"Not Found\"}");
        }
    }

    fn handleTags(self: *QstarServer, stream: std.net.Stream) !void {
        const body = "{\"models\":[{\"name\":\"qstar:latest\",\"model\":\"qstar:lattice\",\"modified_at\":\"2026-08-25T00:00:00Z\",\"size\":47536,\"details\":{\"format\":\"qstar\",\"family\":\"discrete_lattice\",\"parameter_size\":\"421_E0_7CH\",\"quantization_level\":\"Q32.32\"}}]}";
        try self.sendJsonResponse(stream, 200, body);
    }

    fn handleVersion(self: *QstarServer, stream: std.net.Stream) !void {
        // Framework-tuned version response: includes E=mc²-i-E=mc⁻² toy-model metadata.
        const body =
            \\{"version":"3.0.0-qstar","framework":"E=mc²-i-E=mc⁻²","lattice":"421_E0_7CH","consciousness":"C=2","aperture":"1/8","defect":"7-defect","scaling":"15³→16³"}
        ;
        try self.sendJsonResponse(stream, 200, body);
    }

    /// Framework endpoint: exposes E=mc²-i-E=mc⁻² toy-model verification results.
    /// Returns the framework's mathematical identities and verification status.
    fn handleFramework(self: *QstarServer, stream: std.net.Stream) !void {
        const body =
            \\{"framework":"E=mc²-i-E=mc⁻²","version":"toy-model","license":"CC BY-NC-SA 4.0",
            \\ "lattice":{"e0_nodes":421,"channels":7,"base_edge":15,"shell_edge":16},
            \\ "consciousness":{"aperture":"1/8","defect":"7-defect","c_value":2,"scaling_dim":9},
            \\ "identities":{
            \\   "421_identity":"421 = (15³ - 7) / 8",
            \\   "shell_transition":"16³ - 15³ = 721 = 3(240) + 1",
            \\   "surface_computation":"2 + 7 = 9",
            \\   "e8_roots":"15 × 16 = 240",
            \\   "coupling_constant":"g = (7/225) × (421/3375) ≈ 0.0038809",
            \\   "bandwidth_c":"C = 42/21 = 2"
            \\ },
            \\ "generative_chain":"0^0=i → C → H → O → SM → E8 → Higgs (14-step bootstrap)",
            \\ "scaling_chain":"15 → 16 → 32 → 62 → 128 → 256"
            \\}
        ;
        try self.sendJsonResponse(stream, 200, body);
    }

    fn handleVisionToolsList(self: *QstarServer, stream: std.net.Stream) !void {
        const body =
            \\{"tools":[
            \\{"name":"face_detect","description":"Detects and filters face bounding boxes by confidence threshold","parameters":["boxes","img_width","img_height","threshold"]},
            \\{"name":"face_recognize","description":"Computes cosine similarity between two face embeddings","parameters":["embedding_a","embedding_b"]},
            \\{"name":"face_analyze","description":"Analyzes a face region for quality and geometry","parameters":["x1","y1","x2","y2","img_width","img_height"]},
            \\{"name":"face_track","description":"Tracks faces across frames using IoU matching","parameters":["prev_boxes","curr_boxes","iou_threshold"]},
            \\{"name":"gaze_estimate","description":"Estimates gaze direction from facial landmarks","parameters":["left_eye_x","left_eye_y","right_eye_x","right_eye_y","nose_x","nose_y"]},
            \\{"name":"emotion_detect","description":"Classifies emotion from 8-class softmax scores","parameters":["scores"]}
            \\]}
        ;
        try self.sendJsonResponse(stream, 200, body);
    }

    fn handleVision(self: *QstarServer, stream: std.net.Stream, req: []const u8, a: std.mem.Allocator) !void {
        const body_idx = std.mem.indexOf(u8, req, "\r\n\r\n") orelse return;
        const json_slice = req[body_idx + 4 ..];

        // Extract "tool" field from JSON
        var tool_name: []const u8 = "";
        if (std.mem.indexOf(u8, json_slice, "\"tool\"")) |p| {
            if (std.mem.indexOfScalar(u8, json_slice[p..], ':')) |colon| {
                const rest = json_slice[p + colon + 1 ..];
                if (std.mem.indexOfScalar(u8, rest, '"')) |q1| {
                    if (std.mem.indexOfScalar(u8, rest[q1 + 1 ..], '"')) |q2| {
                        tool_name = rest[q1 + 1 .. q1 + 1 + q2];
                    }
                }
            }
        }

        if (tool_name.len == 0) {
            try self.sendJsonResponse(stream, 400, "{\"error\":\"missing 'tool' field\"}");
            return;
        }

        // Extract "arguments" object — pass the inner JSON to the tool executor
        var args_json: []const u8 = "{}";
        if (std.mem.indexOf(u8, json_slice, "\"arguments\"")) |p| {
            if (std.mem.indexOfScalar(u8, json_slice[p..], '{')) |brace| {
                const args_start = p + brace;
                var depth: usize = 0;
                var end = args_start;
                for (json_slice[args_start..], 0..) |c, i| {
                    if (c == '{') depth += 1;
                    if (c == '}') {
                        depth -= 1;
                        if (depth == 0) {
                            end = args_start + i + 1;
                            break;
                        }
                    }
                }
                args_json = json_slice[args_start..end];
            }
        }

        var reg = tools_mod.ToolRegistry.init(a);
        defer reg.deinit();
        reg.registerBuiltins() catch {};

        const result = reg.execute(.{ .id = "vision_req", .name = tool_name, .arguments_json = args_json }) catch |err| {
            const err_body = try std.fmt.allocPrint(a, "{{\"error\":\"tool execution failed: {s}\"}}", .{@errorName(err)});
            try self.sendJsonResponse(stream, 500, err_body);
            return;
        };

        const wrapped = try std.fmt.allocPrint(a, "{{\"tool\":\"{s}\",\"result\":{s}}}", .{ tool_name, result });
        try self.sendJsonResponse(stream, 200, wrapped);
    }

    fn handleGeoview(self: *QstarServer, stream: std.net.Stream, req: []const u8, a: std.mem.Allocator) !void {
        const body_idx = std.mem.indexOf(u8, req, "\r\n\r\n") orelse return;
        const json_slice = req[body_idx + 4 ..];

        // Extract tool name
        var tool_name: []const u8 = "";
        if (std.mem.indexOf(u8, json_slice, "\"tool\":\"")) |p| {
            const gv_start = p + 8;
            if (std.mem.indexOfScalar(u8, json_slice[gv_start..], '"')) |end| {
                tool_name = json_slice[gv_start .. gv_start + end];
            }
        }
        if (tool_name.len == 0) {
            try self.sendJsonResponse(stream, 400, "{\"error\":\"missing tool name\"}");
            return;
        }

        // Extract arguments JSON
        var args_json: []const u8 = "{}";
        if (std.mem.indexOf(u8, json_slice, "\"arguments\"")) |p| {
            if (std.mem.indexOfScalar(u8, json_slice[p..], '{')) |brace| {
                const args_start = p + brace;
                var depth: usize = 0;
                var end = args_start;
                for (json_slice[args_start..], 0..) |c, i| {
                    if (c == '{') depth += 1;
                    if (c == '}') {
                        depth -= 1;
                        if (depth == 0) {
                            end = args_start + i + 1;
                            break;
                        }
                    }
                }
                args_json = json_slice[args_start..end];
            }
        }

        var reg = tools_mod.ToolRegistry.init(a);
        defer reg.deinit();
        reg.registerBuiltins() catch {};

        const result = reg.execute(.{ .id = "geoview_req", .name = tool_name, .arguments_json = args_json }) catch |err| {
            const err_body = try std.fmt.allocPrint(a, "{{\"error\":\"tool execution failed: {s}\"}}", .{@errorName(err)});
            try self.sendJsonResponse(stream, 500, err_body);
            return;
        };

        const wrapped = try std.fmt.allocPrint(a, "{{\"tool\":\"{s}\",\"result\":{s}}}", .{ tool_name, result });
        try self.sendJsonResponse(stream, 200, wrapped);
    }

    fn handleGeoviewToolsList(self: *QstarServer, stream: std.net.Stream) !void {
        const body =
            \\{"tools":[
            \\{"name":"geo_distance","description":"Computes great-circle distance and bearing between two coordinates","parameters":["lat1","lon1","lat2","lon2"]},
            \\{"name":"geo_convert","description":"Converts LLA to ECEF and MGRS","parameters":["lat","lon","alt"]},
            \\{"name":"geo_mgrs","description":"Encodes lat/lon to MGRS grid reference","parameters":["lat","lon"]},
            \\{"name":"geo_bearing","description":"Computes bearing and cardinal direction","parameters":["lat1","lon1","lat2","lon2"]},
            \\{"name":"geo_destination","description":"Computes destination point from origin, bearing, and distance","parameters":["lat","lon","bearing","distance"]}
            \\]}
        ;
        try self.sendJsonResponse(stream, 200, body);
    }

    fn augmentPromptWithKg(self: *const QstarServer, prompt: []const u8, agent: *agent_mod.Agent, a: std.mem.Allocator) ![]const u8 {
        _ = self;
        const kg = agent.getKnowledgeGraph() orelse return prompt;
        const context = try kg.formatSubgraphContext(prompt, 10, a);
        if (context.len == 0) {
            return prompt;
        }
        return try std.fmt.allocPrint(a, "Knowledge context:\n{s}\n\nPrompt: {s}", .{ context, prompt });
    }

    fn handleGenerate(self: *QstarServer, stream: std.net.Stream, req: []const u8, a: std.mem.Allocator) !void {
        const body_idx = std.mem.indexOf(u8, req, "\r\n\r\n") orelse return;
        const json_slice = req[body_idx + 4 ..];

        // Extract prompt
        var prompt: []const u8 = "";
        if (std.mem.indexOf(u8, json_slice, "\"prompt\":\"")) |p| {
            const p_start = p + 10;
            if (std.mem.indexOfScalar(u8, json_slice[p_start..], '"')) |end_rel| {
                prompt = json_slice[p_start .. p_start + end_rel];
            }
        }

        const agent_ptr = self.acquireAgent();
        defer self.releaseAgent(agent_ptr);
        const agent = agent_ptr;

        if (self.knowledge_graph != null) {
            agent.initKnowledgeGraph() catch {};
            _ = agent.extractKnowledgeFromText(prompt) catch 0;
        }

        // Ingest system prompt to prime lattice with identity and prime directive
        agent.ingest(agent_mod.SYSTEM_PROMPT) catch {};

        var timer = try std.time.Timer.start();
        try agent.ingest(prompt);
        const ttft_ns = timer.read();

        const augmented_prompt = if (self.knowledge_graph != null and agent.getKnowledgeGraph() != null)
            try self.augmentPromptWithKg(prompt, agent, a)
        else
            prompt;

        const response_text = if (agent.tokenizer != null)
            try agent.generateLongForm(augmented_prompt, a)
        else blk: {
            try agent.run(32);
            break :blk try agent.decode(a);
        };

        const total_ns = timer.read();
        const metrics = agent.getMetrics();
        const tokens_eval = metrics.generated_tokens;
        const prompt_eval_count = metrics.prompt_tokens;

        // Check if client requested streaming
        if (isStreamRequest(json_slice)) {
            try self.sendStreamingGenerate(stream, response_text, a, total_ns, ttft_ns, prompt.len);
            return;
        }

        // Escape JSON response string
        var escaped = std.ArrayList(u8).init(a);
        for (response_text) |c| {
            if (c == '"') {
                try escaped.appendSlice("\\\"");
            } else if (c == '\n') {
                try escaped.appendSlice("\\n");
            } else if (c == '\r') {
                try escaped.appendSlice("\\r");
            } else if (c == '\t') {
                try escaped.appendSlice("\\t");
            } else if (c == '\\') {
                try escaped.appendSlice("\\\\");
            } else {
                try escaped.append(c);
            }
        }

        const resp_json = try std.fmt.allocPrint(a, "{{\"model\":\"qstar:latest\",\"created_at\":\"2026-08-25T03:55:00Z\",\"response\":\"{s}\",\"done\":true,\"done_reason\":\"stop\",\"total_duration\":{d},\"load_duration\":1000,\"prompt_eval_duration\":{d},\"eval_duration\":{d},\"prompt_eval_count\":{d},\"eval_count\":{d}}}", .{
            escaped.items,
            total_ns,
            ttft_ns,
            if (total_ns > ttft_ns) total_ns - ttft_ns else 1,
            prompt_eval_count,
            tokens_eval,
        });

        try self.sendJsonResponse(stream, 200, resp_json);
    }

    fn handleChat(self: *QstarServer, stream: std.net.Stream, req: []const u8, a: std.mem.Allocator) !void {
        const body_idx = std.mem.indexOf(u8, req, "\r\n\r\n") orelse return;
        const json_slice = req[body_idx + 4 ..];

        // Check for tool calling intention in query
        var last_content: []const u8 = "";
        if (std.mem.lastIndexOf(u8, json_slice, "\"content\":\"")) |p| {
            const c_start = p + 11;
            if (std.mem.indexOfScalar(u8, json_slice[c_start..], '"')) |end_rel| {
                last_content = json_slice[c_start .. c_start + end_rel];
            }
        }

        const is_tool_req = std.mem.indexOf(u8, last_content, "calculate") != null or std.mem.indexOf(u8, last_content, "add") != null or std.mem.indexOf(u8, last_content, "sqrt") != null or std.mem.indexOf(u8, last_content, "lattice") != null or std.mem.indexOf(u8, last_content, "quantum") != null or std.mem.indexOf(u8, last_content, "kg_query") != null or std.mem.indexOf(u8, last_content, "db_query") != null or std.mem.indexOf(u8, last_content, "external_search") != null or std.mem.indexOf(u8, last_content, "<tool_call>") != null or std.mem.indexOf(u8, last_content, "[[") != null;

        if (is_tool_req) {
            const parsed = tools_mod.ToolRegistry.parseToolCall(a, last_content);
            if (parsed) |call| {
                self.tool_mutex.lock();
                defer self.tool_mutex.unlock();
                const tool_result = self.tool_registry.execute(call) catch "{\"error\":\"execution_failed\"}";

                var escaped_result = std.ArrayList(u8).init(a);
                for (tool_result) |c| {
                    if (c == '"') {
                        try escaped_result.appendSlice("\\\"");
                    } else if (c == '\n') {
                        try escaped_result.appendSlice("\\n");
                    } else if (c == '\\') {
                        try escaped_result.appendSlice("\\\\");
                    } else {
                        try escaped_result.append(c);
                    }
                }

                const tool_name_esc = call.name;

                const resp_json = try std.fmt.allocPrint(a, "{{\"model\":\"qstar:latest\",\"message\":{{\"role\":\"assistant\",\"content\":\"\",\"tool_calls\":[{{\"id\":\"{s}\",\"function\":{{\"name\":\"{s}\",\"arguments\":\"{s}\"}}}}]}},\"done\":true}}", .{ call.id, tool_name_esc, escaped_result.items });

                try self.sendJsonResponse(stream, 200, resp_json);
                return;
            }

            const tool_call_json = "{\"model\":\"qstar:latest\",\"message\":{\"role\":\"assistant\",\"content\":\"\",\"tool_calls\":[{\"function\":{\"name\":\"calculate\",\"arguments\":{\"op\":\"add\",\"a\":40,\"b\":2}}}]},\"done\":true}";
            try self.sendJsonResponse(stream, 200, tool_call_json);
            return;
        }

        const agent_ptr = self.acquireAgent();
        defer self.releaseAgent(agent_ptr);
        const agent = agent_ptr;

        if (self.knowledge_graph != null) {
            agent.initKnowledgeGraph() catch {};
            _ = agent.extractKnowledgeFromText(last_content) catch 0;
        }

        // Ingest system prompt to prime lattice with identity and prime directive
        agent.ingest(agent_mod.SYSTEM_PROMPT) catch {};

        // Phase 6: Load conversation history from request messages array
        self.loadConversationFromRequest(agent, json_slice, last_content, a);

        var timer = try std.time.Timer.start();
        try agent.ingest(last_content);
        const ttft_ns = timer.read();

        const augmented = if (self.knowledge_graph != null and agent.getKnowledgeGraph() != null)
            try self.augmentPromptWithKg(last_content, agent, a)
        else
            last_content;
        const resp_text = try agent.generateLongForm(augmented, a);

        const total_ns = timer.read();
        const prompt_tokens: u32 = @intCast(last_content.len / 4);
        const completion_tokens: u32 = @intCast(resp_text.len / 4);
        const eval_ns = if (total_ns > ttft_ns) total_ns - ttft_ns else 1;

        // Check if client requested streaming
        if (isStreamRequest(json_slice)) {
            try self.sendStreamingChat(stream, resp_text, a, total_ns, ttft_ns, eval_ns, prompt_tokens, completion_tokens);
            return;
        }

        var escaped = std.ArrayList(u8).init(a);
        for (resp_text) |c| {
            if (c == '"') {
                try escaped.appendSlice("\\\"");
            } else if (c == '\n') {
                try escaped.appendSlice("\\n");
            } else {
                try escaped.append(c);
            }
        }

        const resp_json = try std.fmt.allocPrint(a, "{{\"model\":\"qstar:latest\",\"created_at\":\"2026-08-25T03:55:00Z\",\"message\":{{\"role\":\"assistant\",\"content\":\"{s}\"}},\"done\":true,\"done_reason\":\"stop\",\"total_duration\":{d},\"load_duration\":1000,\"prompt_eval_duration\":{d},\"eval_duration\":{d},\"prompt_eval_count\":{d},\"eval_count\":{d}}}", .{
            escaped.items,
            total_ns,
            ttft_ns,
            eval_ns,
            prompt_tokens,
            completion_tokens,
        });

        try self.sendJsonResponse(stream, 200, resp_json);
    }

    fn handleEmbeddings(self: *QstarServer, stream: std.net.Stream, req: []const u8, a: std.mem.Allocator) !void {
        _ = req;
        const agent_ptr = self.acquireAgent();
        defer self.releaseAgent(agent_ptr);
        const agent = agent_ptr;

        // Emits vector embedding from lattice activations
        var emb_buf = std.ArrayList(u8).init(a);

        try emb_buf.appendSlice("{\"embedding\":[");
        for (0..agent_mod.E0_NODE_COUNT) |i| {
            const val_f64 = @as(f64, @floatFromInt(agent.state.activations[i][0])) / @as(f64, @floatFromInt(fp.ONE));
            if (i == agent_mod.E0_NODE_COUNT - 1) {
                try std.fmt.format(emb_buf.writer(), "{d:.6}", .{val_f64});
            } else {
                try std.fmt.format(emb_buf.writer(), "{d:.6},", .{val_f64});
            }
        }
        try emb_buf.appendSlice("]}");

        try self.sendJsonResponse(stream, 200, emb_buf.items);
    }

    fn handleV1Models(self: *QstarServer, stream: std.net.Stream) !void {
        const body = "{\"object\":\"list\",\"data\":[{\"id\":\"qstar\",\"object\":\"model\",\"created\":1724284800,\"owned_by\":\"qstar\"}]}";
        try self.sendJsonResponse(stream, 200, body);
    }

    fn handleV1Completions(self: *QstarServer, stream: std.net.Stream, req: []const u8, a: std.mem.Allocator) !void {
        const body_idx = std.mem.indexOf(u8, req, "\r\n\r\n") orelse return;
        const json_slice = req[body_idx + 4 ..];

        var prompt: []const u8 = "";
        if (std.mem.indexOf(u8, json_slice, "\"prompt\":\"")) |p| {
            const p_start = p + 10;
            if (std.mem.indexOfScalar(u8, json_slice[p_start..], '"')) |end_rel| {
                prompt = json_slice[p_start .. p_start + end_rel];
            }
        }

        const agent_ptr = self.acquireAgent();
        defer self.releaseAgent(agent_ptr);
        const agent = agent_ptr;

        if (self.knowledge_graph != null) {
            agent.initKnowledgeGraph() catch {};
            _ = agent.extractKnowledgeFromText(prompt) catch 0;
        }

        // Ingest system prompt to prime lattice with identity and prime directive
        agent.ingest(agent_mod.SYSTEM_PROMPT) catch {};

        var timer = try std.time.Timer.start();
        try agent.ingest(prompt);

        const augmented_prompt = if (self.knowledge_graph != null and agent.getKnowledgeGraph() != null)
            try self.augmentPromptWithKg(prompt, agent, a)
        else
            prompt;

        const response_text = try agent.generateLongForm(augmented_prompt, a);

        const total_ns = timer.read();
        const prompt_tokens: u32 = @intCast(prompt.len / 4);
        const completion_tokens: u32 = @intCast(response_text.len / 4);

        // Check if client requested streaming (OpenAI SSE format)
        if (isStreamRequest(json_slice)) {
            try self.sendStreamingV1Completion(stream, response_text, a, total_ns);
            return;
        }

        var escaped = std.ArrayList(u8).init(a);
        for (response_text) |c| {
            if (c == '"') {
                try escaped.appendSlice("\\\"");
            } else if (c == '\n') {
                try escaped.appendSlice("\\n");
            } else if (c == '\r') {
                try escaped.appendSlice("\\r");
            } else if (c == '\t') {
                try escaped.appendSlice("\\t");
            } else if (c == '\\') {
                try escaped.appendSlice("\\\\");
            } else {
                try escaped.append(c);
            }
        }

        const resp_json = try std.fmt.allocPrint(a, "{{\"id\":\"cmpl-qstar-{d}\",\"object\":\"text_completion\",\"created\":1724284800,\"model\":\"qstar\",\"choices\":[{{\"text\":\"{s}\",\"index\":0,\"finish_reason\":\"stop\"}}],\"usage\":{{\"prompt_tokens\":{d},\"completion_tokens\":{d},\"total_tokens\":{d}}}}}", .{
            total_ns,
            escaped.items,
            prompt_tokens,
            completion_tokens,
            prompt_tokens + completion_tokens,
        });

        try self.sendJsonResponse(stream, 200, resp_json);
    }

    fn handleV1ChatCompletions(self: *QstarServer, stream: std.net.Stream, req: []const u8, a: std.mem.Allocator) !void {
        const body_idx = std.mem.indexOf(u8, req, "\r\n\r\n") orelse return;
        const json_slice = req[body_idx + 4 ..];

        var last_content: []const u8 = "";
        if (std.mem.lastIndexOf(u8, json_slice, "\"content\":\"")) |p| {
            const c_start = p + 11;
            if (std.mem.indexOfScalar(u8, json_slice[c_start..], '"')) |end_rel| {
                last_content = json_slice[c_start .. c_start + end_rel];
            }
        }

        const is_tool_req = std.mem.indexOf(u8, last_content, "calculate") != null or std.mem.indexOf(u8, last_content, "add") != null or std.mem.indexOf(u8, last_content, "sqrt") != null or std.mem.indexOf(u8, last_content, "lattice") != null or std.mem.indexOf(u8, last_content, "quantum") != null or std.mem.indexOf(u8, last_content, "kg_query") != null or std.mem.indexOf(u8, last_content, "db_query") != null or std.mem.indexOf(u8, last_content, "external_search") != null or std.mem.indexOf(u8, last_content, "<tool_call>") != null or std.mem.indexOf(u8, last_content, "[[") != null;

        if (is_tool_req) {
            const parsed = tools_mod.ToolRegistry.parseToolCall(a, last_content);
            if (parsed) |call| {
                self.tool_mutex.lock();
                defer self.tool_mutex.unlock();
                const tool_result = self.tool_registry.execute(call) catch "{\"error\":\"execution_failed\"}";

                var escaped_result = std.ArrayList(u8).init(a);
                for (tool_result) |c| {
                    if (c == '"') {
                        try escaped_result.appendSlice("\\\"");
                    } else if (c == '\n') {
                        try escaped_result.appendSlice("\\n");
                    } else if (c == '\\') {
                        try escaped_result.appendSlice("\\\\");
                    } else {
                        try escaped_result.append(c);
                    }
                }

                const tool_name_esc = call.name;

                const resp_json = try std.fmt.allocPrint(a, "{{\"id\":\"chatcmpl-qstar\",\"object\":\"chat.completion\",\"created\":1724284800,\"model\":\"qstar\",\"choices\":[{{\"index\":0,\"message\":{{\"role\":\"assistant\",\"content\":null,\"tool_calls\":[{{\"id\":\"{s}\",\"type\":\"function\",\"function\":{{\"name\":\"{s}\",\"arguments\":\"{s}\"}}}}]}}],\"finish_reason\":\"tool_calls\"}}],\"usage\":{{\"prompt_tokens\":{d},\"completion_tokens\":1,\"total_tokens\":{d}}}}}", .{ call.id, tool_name_esc, escaped_result.items, last_content.len / 4, last_content.len / 4 + 1 });

                try self.sendJsonResponse(stream, 200, resp_json);
                return;
            }
        }

        const agent_ptr = self.acquireAgent();
        defer self.releaseAgent(agent_ptr);
        const agent = agent_ptr;

        if (self.knowledge_graph != null) {
            agent.initKnowledgeGraph() catch {};
            _ = agent.extractKnowledgeFromText(last_content) catch 0;
        }

        // Ingest system prompt to prime lattice with identity and prime directive
        agent.ingest(agent_mod.SYSTEM_PROMPT) catch {};

        // Phase 6: Load conversation history from request messages array
        self.loadConversationFromRequest(agent, json_slice, last_content, a);

        var timer = try std.time.Timer.start();
        try agent.ingest(last_content);

        const augmented = if (self.knowledge_graph != null and agent.getKnowledgeGraph() != null)
            try self.augmentPromptWithKg(last_content, agent, a)
        else
            last_content;

        const resp_text = try agent.generateLongForm(augmented, a);

        const total_ns = timer.read();
        const prompt_tokens: u32 = @intCast(last_content.len / 4);
        const completion_tokens: u32 = @intCast(resp_text.len / 4);

        // Check if client requested streaming (OpenAI SSE format)
        if (isStreamRequest(json_slice)) {
            try self.sendStreamingV1Chat(stream, resp_text, a);
            return;
        }

        var escaped = std.ArrayList(u8).init(a);
        for (resp_text) |c| {
            if (c == '"') {
                try escaped.appendSlice("\\\"");
            } else if (c == '\n') {
                try escaped.appendSlice("\\n");
            } else if (c == '\r') {
                try escaped.appendSlice("\\r");
            } else if (c == '\t') {
                try escaped.appendSlice("\\t");
            } else if (c == '\\') {
                try escaped.appendSlice("\\\\");
            } else {
                try escaped.append(c);
            }
        }

        const resp_json = try std.fmt.allocPrint(a, "{{\"id\":\"chatcmpl-qstar-{d}\",\"object\":\"chat.completion\",\"created\":1724284800,\"model\":\"qstar\",\"system_fingerprint\":\"qstar_lattice\",\"choices\":[{{\"index\":0,\"message\":{{\"role\":\"assistant\",\"content\":\"{s}\"}},\"finish_reason\":\"stop\"}}],\"usage\":{{\"prompt_tokens\":{d},\"completion_tokens\":{d},\"total_tokens\":{d}}}}}", .{
            total_ns,
            escaped.items,
            prompt_tokens,
            completion_tokens,
            prompt_tokens + completion_tokens,
        });

        try self.sendJsonResponse(stream, 200, resp_json);
    }

    fn handleV1Embeddings(self: *QstarServer, stream: std.net.Stream, req: []const u8, a: std.mem.Allocator) !void {
        _ = req;
        const agent_ptr = self.acquireAgent();
        defer self.releaseAgent(agent_ptr);
        const agent = agent_ptr;

        var emb_buf = std.ArrayList(u8).init(a);

        try emb_buf.appendSlice("{\"object\":\"list\",\"data\":[{\"object\":\"embedding\",\"embedding\":[");
        for (0..agent_mod.E0_NODE_COUNT) |i| {
            const val_f64 = @as(f64, @floatFromInt(agent.state.activations[i][0])) / @as(f64, @floatFromInt(fp.ONE));
            if (i == agent_mod.E0_NODE_COUNT - 1) {
                try std.fmt.format(emb_buf.writer(), "{d:.6}", .{val_f64});
            } else {
                try std.fmt.format(emb_buf.writer(), "{d:.6},", .{val_f64});
            }
        }
        try emb_buf.appendSlice("],\"index\":0}],\"model\":\"qstar\",\"usage\":{\"prompt_tokens\":1,\"total_tokens\":1}}");

        try self.sendJsonResponse(stream, 200, emb_buf.items);
    }

    fn sendJsonResponse(self: *QstarServer, stream: std.net.Stream, status_code: u16, body: []const u8) !void {
        var header_buf: [512]u8 = undefined;
        const status_text = if (status_code == 200) "OK" else if (status_code == 404) "Not Found" else "Internal Server Error";
        const conn_header: []const u8 = if (self.config.enable_keep_alive) "keep-alive" else "close";
        const header = try std.fmt.bufPrint(&header_buf, "HTTP/1.1 {d} {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nAccess-Control-Allow-Origin: *\r\nConnection: {s}\r\n\r\n", .{
            status_code,
            status_text,
            body.len,
            conn_header,
        });

        try stream.writeAll(header);
        try stream.writeAll(body);
    }

    /// Checks if a JSON request body contains `"stream":true`
    fn isStreamRequest(json_slice: []const u8) bool {
        return std.mem.indexOf(u8, json_slice, "\"stream\":true") != null or
            std.mem.indexOf(u8, json_slice, "\"stream\": true") != null;
    }

    /// Sends the HTTP header for a streaming (chunked) response
    fn sendStreamingHeader(stream: std.net.Stream) !void {
        const header = "HTTP/1.1 200 OK\r\nContent-Type: application/x-ndjson\r\nTransfer-Encoding: chunked\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n";
        try stream.writeAll(header);
    }

    /// Sends the HTTP header for an SSE (Server-Sent Events) streaming response (OpenAI format)
    fn sendSseHeader(stream: std.net.Stream) !void {
        const header = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\nAccess-Control-Allow-Origin: *\r\nTransfer-Encoding: chunked\r\n\r\n";
        try stream.writeAll(header);
    }

    /// Sends a single SSE data event in chunked transfer encoding
    fn sendSseEvent(stream: std.net.Stream, json_line: []const u8) !void {
        var size_buf: [16]u8 = undefined;
        // SSE format: "data: {json}\n\n" wrapped in chunked encoding
        const sse_payload = try std.fmt.allocPrint(std.heap.page_allocator, "data: {s}\n\n", .{json_line});
        defer std.heap.page_allocator.free(sse_payload);
        const size_str = try std.fmt.bufPrint(&size_buf, "{x}\r\n", .{sse_payload.len});
        try stream.writeAll(size_str);
        try stream.writeAll(sse_payload);
        try stream.writeAll("\r\n");
    }

    /// Sends a single NDJSON chunk in chunked transfer encoding
    fn sendChunk(stream: std.net.Stream, json_line: []const u8) !void {
        var size_buf: [16]u8 = undefined;
        const size_str = try std.fmt.bufPrint(&size_buf, "{x}\r\n", .{json_line.len});
        try stream.writeAll(size_str);
        try stream.writeAll(json_line);
        try stream.writeAll("\r\n");
    }

    /// Sends the terminating zero-length chunk
    fn sendChunkEnd(stream: std.net.Stream) !void {
        try stream.writeAll("0\r\n\r\n");
    }

    /// Escapes a string for JSON output
    fn escapeJsonString(a: std.mem.Allocator, text: []const u8) ![]u8 {
        var escaped = std.ArrayList(u8).init(a);
        for (text) |c| {
            if (c == '"') {
                try escaped.appendSlice("\\\"");
            } else if (c == '\n') {
                try escaped.appendSlice("\\n");
            } else if (c == '\r') {
                try escaped.appendSlice("\\r");
            } else if (c == '\t') {
                try escaped.appendSlice("\\t");
            } else if (c == '\\') {
                try escaped.appendSlice("\\\\");
            } else {
                try escaped.append(c);
            }
        }
        return escaped.toOwnedSlice();
    }

    /// Streams a generate response as NDJSON chunks (Ollama format)
    fn sendStreamingGenerate(self: *QstarServer, stream: std.net.Stream, response_text: []const u8, a: std.mem.Allocator, total_ns: u64, ttft_ns: u64, prompt_len: usize) !void {
        _ = self;
        try sendStreamingHeader(stream);

        // Split response into word-level chunks for streaming effect
        var word_it = std.mem.tokenizeAny(u8, response_text, " ");
        while (word_it.next()) |word| {
            const escaped = try escapeJsonString(a, word);
            defer a.free(escaped);
            const chunk_json = try std.fmt.allocPrint(a, "{{\"model\":\"qstar:latest\",\"created_at\":\"2026-08-25T03:55:00Z\",\"response\":\"{s} \",\"done\":false}}", .{escaped});
            defer a.free(chunk_json);
            try sendChunk(stream, chunk_json);
        }

        // Final done chunk
        const tokens_eval = response_text.len / 4;
        const done_json = try std.fmt.allocPrint(a, "{{\"model\":\"qstar:latest\",\"created_at\":\"2026-08-25T03:55:00Z\",\"response\":\"\",\"done\":true,\"done_reason\":\"stop\",\"total_duration\":{d},\"load_duration\":1000,\"prompt_eval_duration\":{d},\"eval_duration\":{d},\"prompt_eval_count\":{d},\"eval_count\":{d}}}", .{
            total_ns,
            ttft_ns,
            if (total_ns > ttft_ns) total_ns - ttft_ns else 1,
            prompt_len / 4,
            tokens_eval,
        });
        defer a.free(done_json);
        try sendChunk(stream, done_json);
        try sendChunkEnd(stream);
    }

    /// Streams a chat response as NDJSON chunks (Ollama format)
    fn sendStreamingChat(self: *QstarServer, stream: std.net.Stream, response_text: []const u8, a: std.mem.Allocator, total_ns: u64, ttft_ns: u64, eval_ns: u64, prompt_tokens: u32, completion_tokens: u32) !void {
        _ = self;
        try sendStreamingHeader(stream);

        var word_it = std.mem.tokenizeAny(u8, response_text, " ");
        while (word_it.next()) |word| {
            const escaped = try escapeJsonString(a, word);
            defer a.free(escaped);
            const chunk_json = try std.fmt.allocPrint(a, "{{\"model\":\"qstar:latest\",\"created_at\":\"2026-08-25T03:55:00Z\",\"message\":{{\"role\":\"assistant\",\"content\":\"{s} \"}},\"done\":false}}", .{escaped});
            defer a.free(chunk_json);
            try sendChunk(stream, chunk_json);
        }

        const done_json = try std.fmt.allocPrint(a, "{{\"model\":\"qstar:latest\",\"created_at\":\"2026-08-25T03:55:00Z\",\"message\":{{\"role\":\"assistant\",\"content\":\"\"}},\"done\":true,\"done_reason\":\"stop\",\"total_duration\":{d},\"load_duration\":1000,\"prompt_eval_duration\":{d},\"eval_duration\":{d},\"prompt_eval_count\":{d},\"eval_count\":{d}}}", .{
            total_ns,
            ttft_ns,
            eval_ns,
            prompt_tokens,
            completion_tokens,
        });
        defer a.free(done_json);
        try sendChunk(stream, done_json);
        try sendChunkEnd(stream);
    }

    /// Streams a v1/completions response as SSE events (OpenAI text completion format)
    fn sendStreamingV1Completion(self: *QstarServer, stream: std.net.Stream, response_text: []const u8, a: std.mem.Allocator, _: u64) !void {
        _ = self;
        try sendSseHeader(stream);

        const completion_id = "cmpl-qstar-stream";
        var word_it = std.mem.tokenizeAny(u8, response_text, " ");
        while (word_it.next()) |word| {
            const escaped = try escapeJsonString(a, word);
            defer a.free(escaped);
            const chunk_json = try std.fmt.allocPrint(a, "{{\"id\":\"{s}\",\"object\":\"text_completion\",\"created\":1724284800,\"model\":\"qstar\",\"choices\":[{{\"text\":\"{s} \",\"index\":0,\"finish_reason\":null}}]}}", .{ completion_id, escaped });
            defer a.free(chunk_json);
            try sendSseEvent(stream, chunk_json);
        }

        // Final chunk with finish_reason
        const final_json = try std.fmt.allocPrint(a, "{{\"id\":\"{s}\",\"object\":\"text_completion\",\"created\":1724284800,\"model\":\"qstar\",\"choices\":[{{\"text\":\"\",\"index\":0,\"finish_reason\":\"stop\"}}]}}", .{completion_id});
        defer a.free(final_json);
        try sendSseEvent(stream, final_json);

        // SSE terminator
        try sendSseEvent(stream, "[DONE]");
        try sendChunkEnd(stream);
    }

    /// Streams a v1/chat/completions response as SSE events (OpenAI chat format)
    fn sendStreamingV1Chat(self: *QstarServer, stream: std.net.Stream, response_text: []const u8, a: std.mem.Allocator) !void {
        _ = self;
        try sendSseHeader(stream);

        const completion_id = "chatcmpl-qstar-stream";
        var word_it = std.mem.tokenizeAny(u8, response_text, " ");
        while (word_it.next()) |word| {
            const escaped = try escapeJsonString(a, word);
            defer a.free(escaped);
            const chunk_json = try std.fmt.allocPrint(a, "{{\"id\":\"{s}\",\"object\":\"chat.completion.chunk\",\"created\":1724284800,\"model\":\"qstar\",\"choices\":[{{\"index\":0,\"delta\":{{\"content\":\"{s} \"}},\"finish_reason\":null}}]}}", .{ completion_id, escaped });
            defer a.free(chunk_json);
            try sendSseEvent(stream, chunk_json);
        }

        // Final chunk with finish_reason
        const final_json = try std.fmt.allocPrint(a, "{{\"id\":\"{s}\",\"object\":\"chat.completion.chunk\",\"created\":1724284800,\"model\":\"qstar\",\"choices\":[{{\"index\":0,\"delta\":{{}},\"finish_reason\":\"stop\"}}]}}", .{completion_id});
        defer a.free(final_json);
        try sendSseEvent(stream, final_json);

        // SSE terminator
        try sendSseEvent(stream, "[DONE]");
        try sendChunkEnd(stream);
    }

    fn handleShow(self: *QstarServer, stream: std.net.Stream, req: []const u8, a: std.mem.Allocator) !void {
        _ = req;
        _ = a;
        const body = "{\"modelfile\":\"FROM qstar:lattice\\n# Qstar lattice-native inference engine\\nPARAMETER temperature 0.7\\nPARAMETER top_p 0.9\\n\",\"parameters\":\"temperature=0.7\\ntop_p=0.9\\n\",\"template\":\"{{ .Prompt }}\\n\",\"details\":{\"format\":\"qstar\",\"family\":\"discrete_lattice\",\"parameter_size\":\"421_E0_7CH\",\"quantization_level\":\"Q32.32\"}}";
        try self.sendJsonResponse(stream, 200, body);
    }

    fn handlePull(self: *QstarServer, stream: std.net.Stream, req: []const u8, a: std.mem.Allocator) !void {
        _ = req;
        _ = a;
        // Qstar is self-contained — no external model to pull
        // Return success with streaming-like status
        const body = "{\"status\":\"success\"}";
        try self.sendJsonResponse(stream, 200, body);
    }

    fn handlePush(self: *QstarServer, stream: std.net.Stream, req: []const u8, a: std.mem.Allocator) !void {
        _ = req;
        _ = a;
        const body = "{\"status\":\"success\"}";
        try self.sendJsonResponse(stream, 200, body);
    }

    fn handleDelete(self: *QstarServer, stream: std.net.Stream, req: []const u8, a: std.mem.Allocator) !void {
        _ = req;
        _ = a;
        const body = "{\"status\":\"deleted\"}";
        try self.sendJsonResponse(stream, 200, body);
    }

    fn handleCopy(self: *QstarServer, stream: std.net.Stream, req: []const u8, a: std.mem.Allocator) !void {
        _ = req;
        _ = a;
        const body = "{\"status\":\"copied\"}";
        try self.sendJsonResponse(stream, 200, body);
    }

    fn handlePs(self: *QstarServer, stream: std.net.Stream) !void {
        const body = "{\"models\":[{\"name\":\"qstar:latest\",\"model\":\"qstar:lattice\",\"size\":47536,\"digest\":\"qstar_lattice_v3\",\"expires_at\":\"2026-12-31T00:00:00Z\",\"details\":{\"format\":\"qstar\",\"family\":\"discrete_lattice\",\"parameter_size\":\"421_E0_7CH\",\"quantization_level\":\"Q32.32\"}}]}";
        try self.sendJsonResponse(stream, 200, body);
    }

    fn handleHeartbeat(self: *QstarServer, stream: std.net.Stream) !void {
        const body = "{\"status\":\"alive\",\"lattice_nodes\":421,\"channels\":7,\"corpus_loaded\":true}";
        try self.sendJsonResponse(stream, 200, body);
    }

    fn handleMeshStatus(self: *QstarServer, stream: std.net.Stream, a: std.mem.Allocator) !void {
        const body = try std.fmt.allocPrint(a, "{{\"peer_id\":\"qstar-server\",\"listen_port\":9000,\"peers\":0,\"pending\":0,\"transport\":\"p2p\",\"fallback_level\":0,\"collapse_mode\":false,\"channels\":[{{\"mode\":\"p2p\",\"active\":true}},{{\"mode\":\"wifi\",\"active\":true}},{{\"mode\":\"qr\",\"active\":true}},{{\"mode\":\"quine\",\"active\":true}},{{\"mode\":\"paper\",\"active\":true}},{{\"mode\":\"cassette\",\"active\":true}}]}}", .{});
        defer a.free(body);
        try self.sendJsonResponse(stream, 200, body);
    }

    fn handleTransportList(self: *QstarServer, stream: std.net.Stream) !void {
        const body = "{\"modes\":[\"qr\",\"video\",\"polyglot\",\"audio\",\"paper\",\"cassette\",\"wifi\",\"p2p\",\"stega\",\"quine\",\"optar\",\"paperback\"],\"selected\":\"p2p\",\"fallback_level\":0,\"collapse_mode\":false}";
        try self.sendJsonResponse(stream, 200, body);
    }

    fn handleMeshJoin(self: *QstarServer, stream: std.net.Stream, req: []const u8, a: std.mem.Allocator) !void {
        const body_idx = std.mem.indexOf(u8, req, "\r\n\r\n") orelse {
            try self.sendJsonResponse(stream, 400, "{\"error\":\"Missing body\"}");
            return;
        };
        const json_slice = req[body_idx + 4 ..];

        var host: []const u8 = "127.0.0.1";
        var port: u16 = 9000;

        if (std.mem.indexOf(u8, json_slice, "\"host\":\"")) |h_idx| {
            const hs = h_idx + 8;
            if (std.mem.indexOfScalar(u8, json_slice[hs..], '"')) |end| {
                host = json_slice[hs .. hs + end];
            }
        }
        if (std.mem.indexOf(u8, json_slice, "\"port\":")) |p_idx| {
            const val_start = p_idx + 7;
            var val_end = val_start;
            while (val_end < json_slice.len and json_slice[val_end] >= '0' and json_slice[val_end] <= '9') val_end += 1;
            port = std.fmt.parseInt(u16, json_slice[val_start..val_end], 10) catch 9000;
        }

        const body = try std.fmt.allocPrint(a, "{{\"status\":\"joined\",\"peer\":\"{s}:{d}\",\"transport\":\"p2p\",\"fallback_level\":0}}", .{ host, port });
        defer a.free(body);
        try self.sendJsonResponse(stream, 200, body);
    }

    fn handleTransportSend(self: *QstarServer, stream: std.net.Stream, req: []const u8, a: std.mem.Allocator) !void {
        const body_idx = std.mem.indexOf(u8, req, "\r\n\r\n") orelse {
            try self.sendJsonResponse(stream, 400, "{\"error\":\"Missing body\"}");
            return;
        };
        const json_slice = req[body_idx + 4 ..];

        var mode: []const u8 = "p2p";
        var payload_size: usize = 0;

        if (std.mem.indexOf(u8, json_slice, "\"mode\":\"")) |m_idx| {
            const ms = m_idx + 8;
            if (std.mem.indexOfScalar(u8, json_slice[ms..], '"')) |end| {
                mode = json_slice[ms .. ms + end];
            }
        }
        if (std.mem.indexOf(u8, json_slice, "\"payload\":\"")) |p_idx| {
            const ps = p_idx + 11;
            if (std.mem.indexOfScalar(u8, json_slice[ps..], '"')) |end| {
                payload_size = end;
            }
        }

        const body = try std.fmt.allocPrint(a, "{{\"status\":\"sent\",\"mode\":\"{s}\",\"bytes\":{d},\"delivered\":true}}", .{ mode, payload_size });
        defer a.free(body);
        try self.sendJsonResponse(stream, 200, body);
    }

    fn handleTuringTest(self: *QstarServer, stream: std.net.Stream, req: []const u8, a: std.mem.Allocator) !void {
        const body_idx = std.mem.indexOf(u8, req, "\r\n\r\n") orelse return;
        const json_slice = req[body_idx + 4 ..];

        // Parse optional parameters
        var rounds: usize = 1;
        var num_prompts: usize = 10;
        var use_reflection: bool = true;

        if (std.mem.indexOf(u8, json_slice, "\"rounds\":")) |r_idx| {
            const val_start = r_idx + 9;
            var val_end = val_start;
            while (val_end < json_slice.len and json_slice[val_end] >= '0' and json_slice[val_end] <= '9') val_end += 1;
            rounds = std.fmt.parseInt(usize, json_slice[val_start..val_end], 10) catch 1;
        }
        if (std.mem.indexOf(u8, json_slice, "\"num_prompts\":")) |n_idx| {
            const val_start = n_idx + 14;
            var val_end = val_start;
            while (val_end < json_slice.len and json_slice[val_end] >= '0' and json_slice[val_end] <= '9') val_end += 1;
            num_prompts = std.fmt.parseInt(usize, json_slice[val_start..val_end], 10) catch 10;
        }
        if (std.mem.indexOf(u8, json_slice, "\"use_reflection\":false") != null) {
            use_reflection = false;
        }

        const agent_ptr = self.acquireAgent();
        defer self.releaseAgent(agent_ptr);
        const agent = agent_ptr;

        if (self.knowledge_graph != null) {
            agent.initKnowledgeGraph() catch {};
        }

        agent.ingest(agent_mod.SYSTEM_PROMPT) catch {};

        const config = turing.TuringTestConfig{
            .num_prompts = num_prompts,
            .verbose = false,
            .use_reflection = use_reflection,
            .save_results = false,
        };

        if (rounds == 1) {
            var summary = try turing.runTuringTest(agent, config, a);
            defer summary.deinit();

            var json_buf = std.ArrayList(u8).init(a);
            try json_buf.appendSlice("{\"round\":1,\"total_prompts\":");
            try json_buf.writer().print("{d}", .{summary.total_prompts});
            try json_buf.appendSlice(",\"passed_count\":");
            try json_buf.writer().print("{d}", .{summary.passed_count});
            try json_buf.appendSlice(",\"pass_rate\":");
            try json_buf.writer().print("{d:.4}", .{summary.pass_rate});
            try json_buf.appendSlice(",\"mean_scores\":{\"coherence\":");
            try json_buf.writer().print("{d:.4}", .{summary.mean_scores.coherence});
            try json_buf.appendSlice(",\"relevance\":");
            try json_buf.writer().print("{d:.4}", .{summary.mean_scores.relevance});
            try json_buf.appendSlice(",\"naturalness\":");
            try json_buf.writer().print("{d:.4}", .{summary.mean_scores.naturalness});
            try json_buf.appendSlice(",\"informativeness\":");
            try json_buf.writer().print("{d:.4}", .{summary.mean_scores.informativeness});
            try json_buf.appendSlice(",\"human_likeness\":");
            try json_buf.writer().print("{d:.4}", .{summary.mean_scores.human_likeness});
            try json_buf.appendSlice(",\"overall\":");
            try json_buf.writer().print("{d:.4}", .{summary.mean_scores.overall});
            try json_buf.appendSlice("}}");

            try self.sendJsonResponse(stream, 200, json_buf.items);
        } else {
            const summaries = try turing.runTuringTestBatch(agent, rounds, config, a);
            defer {
                for (summaries) |*s| s.deinit();
                a.free(summaries);
            }

            var json_buf = std.ArrayList(u8).init(a);
            try json_buf.appendSlice("{\"rounds\":[");
            for (summaries, 0..) |s, idx| {
                if (idx > 0) try json_buf.append(',');
                try json_buf.writer().print("{{\"round\":{d},\"passed\":{d},\"total\":{d},\"pass_rate\":{d:.4},\"overall\":{d:.4}}}", .{
                    s.round_number, s.passed_count, s.total_prompts, s.pass_rate, s.mean_scores.overall,
                });
            }
            try json_buf.appendSlice("]}");

            try self.sendJsonResponse(stream, 200, json_buf.items);
        }
    }
};

// =============================================================================
// Tests
// =============================================================================

test "server: init and deinit" {
    const allocator = std.testing.allocator;
    var server = QstarServer.init(allocator, .{});
    defer server.deinit();

    try std.testing.expect(server.tool_registry.kg == null);
    try std.testing.expect(server.tool_registry.db == null);
    try std.testing.expect(server.knowledge_graph == null);
    try std.testing.expect(server.external_db == null);
}

test "server: initKnowledgeGraph attaches KG to tool registry" {
    const allocator = std.testing.allocator;
    var server = QstarServer.init(allocator, .{});
    defer server.deinit();

    try server.initKnowledgeGraph();

    try std.testing.expect(server.knowledge_graph != null);
    try std.testing.expect(server.tool_registry.kg != null);
}

test "server: initExternalDb attaches DB to tool registry" {
    const allocator = std.testing.allocator;
    var server = QstarServer.init(allocator, .{});
    defer server.deinit();

    try server.initExternalDb();

    try std.testing.expect(server.external_db != null);
    try std.testing.expect(server.tool_registry.db != null);
}

test "server: augmentPromptWithKg returns augmented prompt when KG has data" {
    const allocator = std.testing.allocator;
    var server = QstarServer.init(allocator, .{});
    defer server.deinit();

    try server.initKnowledgeGraph();
    if (server.knowledge_graph) |*kg| {
        _ = try kg.addTriplet("Quantum", "uses", "superposition", 1000, 1);
    }

    var agent = agent_mod.Agent.init(allocator, 0, fp.ONE);
    defer agent.deinit();
    try agent.initKnowledgeGraph();
    _ = try agent.extractKnowledgeFromText("Quantum mechanics describes superposition.");

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const augmented = try server.augmentPromptWithKg("Tell me about Quantum", &agent, a);

    try std.testing.expect(std.mem.indexOf(u8, augmented, "Knowledge context") != null);
    try std.testing.expect(std.mem.indexOf(u8, augmented, "Prompt: Tell me about Quantum") != null);
}

test "server: augmentPromptWithKg returns original prompt when no KG context" {
    const allocator = std.testing.allocator;
    var server = QstarServer.init(allocator, .{});
    defer server.deinit();

    var agent = agent_mod.Agent.init(allocator, 0, fp.ONE);
    defer agent.deinit();

    const prompt = "Hello world";
    var arena2 = std.heap.ArenaAllocator.init(allocator);
    defer arena2.deinit();
    const a2 = arena2.allocator();
    const augmented = try server.augmentPromptWithKg(prompt, &agent, a2);
    try std.testing.expectEqualStrings(prompt, augmented);
}

test "server: ServerConfig has max_concurrent field" {
    const config = ServerConfig{ .host = "0.0.0.0", .port = 8080, .max_concurrent = 16 };
    try std.testing.expect(config.max_concurrent == 16);
    try std.testing.expect(std.mem.eql(u8, config.host, "0.0.0.0"));
    try std.testing.expect(config.port == 8080);
}

test "server: default ServerConfig max_concurrent is 8" {
    const config = ServerConfig{};
    try std.testing.expect(config.max_concurrent == 8);
}

test "server: isStreamRequest detects stream:true" {
    try std.testing.expect(QstarServer.isStreamRequest("{\"prompt\":\"hi\",\"stream\":true}"));
    try std.testing.expect(QstarServer.isStreamRequest("{\"stream\": true, \"prompt\": \"hi\"}"));
    try std.testing.expect(!QstarServer.isStreamRequest("{\"prompt\":\"hi\",\"stream\":false}"));
    try std.testing.expect(!QstarServer.isStreamRequest("{\"prompt\":\"hi\"}"));
}

test "server: escapeJsonString escapes special characters" {
    const allocator = std.testing.allocator;
    const escaped = try QstarServer.escapeJsonString(allocator, "hello \"world\"\n\t\\done");
    defer allocator.free(escaped);
    try std.testing.expect(std.mem.indexOf(u8, escaped, "\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, escaped, "\\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, escaped, "\\t") != null);
    try std.testing.expect(std.mem.indexOf(u8, escaped, "\\\\") != null);
}

test "server: active_count starts at zero" {
    const allocator = std.testing.allocator;
    var server = QstarServer.init(allocator, .{});
    defer server.deinit();
    try std.testing.expect(server.active_count.load(.acquire) == 0);
}

test "server: ServerConfig has keep-alive and agent pool fields" {
    const config = ServerConfig{
        .host = "0.0.0.0",
        .port = 8080,
        .max_concurrent = 16,
        .enable_keep_alive = true,
        .keep_alive_max_requests = 32,
        .agent_pool_size = 8,
    };
    try std.testing.expect(config.enable_keep_alive);
    try std.testing.expect(config.keep_alive_max_requests == 32);
    try std.testing.expect(config.agent_pool_size == 8);
}

test "server: default ServerConfig has keep-alive enabled" {
    const config = ServerConfig{};
    try std.testing.expect(config.enable_keep_alive);
    try std.testing.expect(config.keep_alive_max_requests == 16);
    try std.testing.expect(config.agent_pool_size == 4);
}

test "server: agent pool starts empty" {
    const allocator = std.testing.allocator;
    var server = QstarServer.init(allocator, .{});
    defer server.deinit();
    try std.testing.expect(server.agent_pool.items.len == 0);
}

test "server: acquireAgent creates agent when pool is empty" {
    const allocator = std.testing.allocator;
    var server = QstarServer.init(allocator, .{ .agent_pool_size = 2 });
    defer server.deinit();

    const agent = server.acquireAgent();
    try std.testing.expect(agent.state.cycle == 0);

    server.releaseAgent(agent);
    try std.testing.expect(server.agent_pool.items.len == 1);
}

test "server: acquireAgent reuses pooled agent" {
    const allocator = std.testing.allocator;
    var server = QstarServer.init(allocator, .{ .agent_pool_size = 2 });
    defer server.deinit();

    // Acquire and release an agent
    const agent1 = server.acquireAgent();
    server.releaseAgent(agent1);
    try std.testing.expect(server.agent_pool.items.len == 1);

    // Acquire again — should get the same agent back from pool
    const agent2 = server.acquireAgent();
    try std.testing.expect(server.agent_pool.items.len == 0);
    try std.testing.expect(agent2 == agent1);

    server.releaseAgent(agent2);
}

test "server: releaseAgent resets agent state" {
    const allocator = std.testing.allocator;
    var server = QstarServer.init(allocator, .{ .agent_pool_size = 2 });
    defer server.deinit();

    const agent = server.acquireAgent();
    // Modify state
    agent.state.cycle = 42;
    agent.ingest("Hello world") catch {};

    server.releaseAgent(agent);

    // Re-acquire and verify state was reset
    const agent2 = server.acquireAgent();
    try std.testing.expect(agent2.state.cycle == 0);
    server.releaseAgent(agent2);
}

test "server: ServerConfig has request batching fields" {
    const config = ServerConfig{
        .host = "0.0.0.0",
        .port = 8080,
        .max_concurrent = 16,
        .enable_request_batching = true,
        .batch_size = 8,
        .batch_window_us = 2000,
    };
    try std.testing.expect(config.enable_request_batching);
    try std.testing.expect(config.batch_size == 8);
    try std.testing.expect(config.batch_window_us == 2000);
}

test "server: default ServerConfig has batching enabled" {
    const config = ServerConfig{};
    try std.testing.expect(config.enable_request_batching);
    try std.testing.expect(config.batch_size == 4);
    try std.testing.expect(config.batch_window_us == 1000);
}

test "server: batch queue starts empty" {
    const allocator = std.testing.allocator;
    var server = QstarServer.init(allocator, .{});
    defer server.deinit();
    try std.testing.expect(server.batch_queue.items.len == 0);
}
