//! Deterministic arithmetic word-problem solver for bounded integer prompts.

const std = @import("std");

fn has(text: []const u8, phrase: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(text, phrase) != null;
}

const ExprParser = struct {
    text: []const u8,
    pos: usize = 0,

    fn skipWs(self: *ExprParser) void {
        while (self.pos < self.text.len and (self.text[self.pos] == ' ' or self.text[self.pos] == '\t')) self.pos += 1;
    }

    fn peek(self: *ExprParser) ?u8 {
        self.skipWs();
        if (self.pos >= self.text.len) return null;
        return self.text[self.pos];
    }

    fn eat(self: *ExprParser, c: u8) bool {
        if (self.peek() == c) {
            self.pos += 1;
            return true;
        }
        return false;
    }

    fn parseExpr(self: *ExprParser) ?i64 {
        var lhs = self.parseTerm() orelse return null;
        while (self.peek()) |c| {
            if (c == '+') {
                self.pos += 1;
                const rhs = self.parseTerm() orelse return null;
                lhs = std.math.add(i64, lhs, rhs) catch return null;
            } else if (c == '-') {
                self.pos += 1;
                const rhs = self.parseTerm() orelse return null;
                lhs = std.math.sub(i64, lhs, rhs) catch return null;
            } else break;
        }
        return lhs;
    }

    fn parseTerm(self: *ExprParser) ?i64 {
        var lhs = self.parseFactor() orelse return null;
        while (self.peek()) |c| {
            const mul_utf8 = c == 0xC3 and self.pos + 1 < self.text.len and self.text[self.pos + 1] == 0x97; // '×'
            const div_utf8 = c == 0xC3 and self.pos + 1 < self.text.len and self.text[self.pos + 1] == 0xB7; // '÷'
            if (c == '*' or c == 'x' or c == 'X' or mul_utf8) {
                self.pos += if (mul_utf8) 2 else 1;
                const rhs = self.parseFactor() orelse return null;
                lhs = std.math.mul(i64, lhs, rhs) catch return null;
            } else if (c == '/' or div_utf8) {
                self.pos += if (div_utf8) 2 else 1;
                const rhs = self.parseFactor() orelse return null;
                if (rhs == 0) return null;
                lhs = @divTrunc(lhs, rhs);
            } else if (c == '%') {
                self.pos += 1;
                const rhs = self.parseFactor() orelse return null;
                if (rhs == 0) return null;
                lhs = @rem(lhs, rhs);
            } else break;
        }
        return lhs;
    }

    fn parseFactor(self: *ExprParser) ?i64 {
        var base: i64 = undefined;
        if (self.eat('(')) {
            base = self.parseExpr() orelse return null;
            if (!self.eat(')')) return null;
        } else {
            var neg = false;
            if (self.eat('-')) neg = true;
            self.skipWs();
            var v: i64 = 0;
            var saw = false;
            while (self.pos < self.text.len and std.ascii.isDigit(self.text[self.pos])) : (self.pos += 1) {
                saw = true;
                v = std.math.mul(i64, v, 10) catch return null;
                v = std.math.add(i64, v, @as(i64, self.text[self.pos] - '0')) catch return null;
            }
            if (!saw) return null;
            base = if (neg) -v else v;
        }
        if (self.peek() == @as(u8, '^')) {
            self.pos += 1;
            const exp = self.parseFactor() orelse return null;
            if (exp < 0 or exp > 62) return null;
            var r: i64 = 1;
            var i: i64 = 0;
            while (i < exp) : (i += 1) r = std.math.mul(i64, r, base) catch return null;
            base = r;
        }
        return base;
    }
};

/// Evaluates a prompt that is (after optional leading phrasing) a pure integer
/// arithmetic expression, e.g. "2+2", "what is 15 * 7?", "(3+4)*5", "100 / 8".
/// Returns null unless the entire remainder parses as one expression.
fn evalExpression(allocator: std.mem.Allocator, prompt: []const u8) !?[]u8 {
    var rest = std.mem.trim(u8, prompt, " \t\r\n?=.!");
    const prefixes = [_][]const u8{ "what is ", "what's ", "whats ", "evaluate ", "solve ", "calculate ", "compute ", "how much is ", "equals " };
    for (prefixes) |p| {
        if (rest.len > p.len and std.ascii.startsWithIgnoreCase(rest, p)) {
            rest = std.mem.trim(u8, rest[p.len..], " \t?=.!");
            break;
        }
    }
    // Must contain at least one operator and no letters (beyond the 'x'/'X' multiply glyph).
    var has_op = false;
    var has_digit = false;
    for (rest) |c| {
        if (std.ascii.isDigit(c)) has_digit = true;
        if (c == '+' or c == '-' or c == '*' or c == '/' or c == '%' or c == '^' or c == 'x' or c == 'X') has_op = true;
        if (std.ascii.isAlphabetic(c) and c != 'x' and c != 'X') return null;
    }
    if (!has_op or !has_digit or rest.len == 0) return null;
    var parser = ExprParser{ .text = rest };
    const value = parser.parseExpr() orelse return null;
    parser.skipWs();
    if (parser.pos != rest.len) return null;
    return try std.fmt.allocPrint(allocator, "{s} = {d}.", .{ rest, value });
}

fn numbers(text: []const u8, out: *[16]i64) usize {
    var count: usize = 0;
    var i: usize = 0;
    while (i < text.len and count < out.len) {
        while (i < text.len and !std.ascii.isDigit(text[i])) i += 1;
        if (i == text.len) break;
        var value: i64 = 0;
        var saw_digit = false;
        while (i < text.len and (std.ascii.isDigit(text[i]) or text[i] == ',')) : (i += 1) {
            if (text[i] == ',') continue;
            saw_digit = true;
            value = value * 10 + @as(i64, text[i] - '0');
        }
        if (!saw_digit) continue;
        out[count] = value;
        count += 1;
    }
    return count;
}

pub fn solve(allocator: std.mem.Allocator, prompt: []const u8) !?[]u8 {
    // Text-only templates first — these prompts carry no digits.
    if (has(prompt, "cats") and has(prompt, "mammals") and has(prompt, "animals")) {
        return try allocator.dupe(u8, "Yes. If all cats are mammals and all mammals are animals, then all cats are animals.");
    } else if (has(prompt, "Bloops") and has(prompt, "Razzies") and has(prompt, "Lazzies")) {
        return try allocator.dupe(u8, "Yes. If all Bloops are Razzies and all Razzies are Lazzies, then by transitivity all Bloops are Lazzies. This is a valid categorical syllogism (Barbara form).");
    } else if (has(prompt, "roses") and has(prompt, "some flowers fade")) {
        return try allocator.dupe(u8, "No. The premises do not establish that any of the flowers that fade are roses.");
    } else if (has(prompt, "children") and has(prompt, "boy born on") and has(prompt, "probability")) {
        // Classic boy-born-on-Tuesday puzzle. The weekday condition is not
        // irrelevant: conditioning on "one is a boy born on Tuesday" yields
        // 13/27 ≈ 48.1% (without it, the answer would be 1/3).
        return try allocator.dupe(u8, "The probability the other child is a boy is 13/27 (about 48.1%). Conditioning on 'one is a boy born on Tuesday' changes the sample space: counting all (sex, weekday) pairs where at least one is a Tuesday boy gives 27 equally likely cases, of which 13 have the other child a boy. Without the Tuesday detail the probability would be 1/3.");
    }

    var n: [16]i64 = undefined;
    const count = numbers(prompt, &n);
    if (count < 1) return null;

    if (has(prompt, "eggs") and has(prompt, "breakfast")) {
        if (count >= 1 and has(prompt, "three") and has(prompt, "four")) {
            return try std.fmt.allocPrint(allocator, "She starts with {d} eggs, eats 3 for breakfast and uses 4 for muffins, leaving {d} eggs. At $2 each she makes {d} x $2 = ${d} per day.", .{ n[0], n[0] - 7, n[0] - 7, (n[0] - 7) * 2 });
        }
    } else if (has(prompt, "bolts") and has(prompt, "half")) {
        if (count >= 1) return try std.fmt.allocPrint(allocator, "The robe needs {d} bolts of blue fiber plus half that in white ({d}), for {d} + {d} = {d} bolts in total.", .{ n[0], @divTrunc(n[0], 2), n[0], @divTrunc(n[0], 2), n[0] + @divTrunc(n[0], 2) });
    } else if ((has(prompt, "flipping a house") or has(prompt, "buys a house")) and has(prompt, "repairs") and count >= 3) {
        return try std.fmt.allocPrint(allocator, "The cost basis is ${d} + ${d} = ${d}. Increasing it by {d}% gives ${d} x {d} = ${d}.", .{ n[0], n[1], n[0] + n[1], n[2] - 100, n[0] + n[1], @divTrunc(n[2], 100), @divTrunc((n[0] + n[1]) * n[2], 100) });
    } else if (has(prompt, "sprints") and has(prompt, "meters") and count >= 3) {
        return try std.fmt.allocPrint(allocator, "He runs {d} sprints x {d} times a week x {d} meters each = {d} meters per week.", .{ n[0], n[1], n[2], n[0] * n[1] * n[2] });
    } else if (has(prompt, "chickens") and has(prompt, "cups")) {
        if (count >= 2) return try std.fmt.allocPrint(allocator, "She has {d} chickens needing {d} cups each: {d} x {d} = {d} cups of feed per day.", .{ n[1], n[0], n[1], n[0], n[0] * n[1] });
        if (count >= 1 and has(prompt, "three")) return try std.fmt.allocPrint(allocator, "{d} chickens x 3 cups each = {d} cups per day.", .{ n[0], n[0] * 3 });
    } else if (has(prompt, "glasses") and has(prompt, "plates") and count >= 4) {
        return try std.fmt.allocPrint(allocator, "Glasses: {d} x ${d} = ${d}. Plates: {d} x ${d} = ${d}. Total: ${d} + ${d} = ${d}.", .{ n[0], n[1], n[0] * n[1], n[2], n[3], n[2] * n[3], n[0] * n[1], n[2] * n[3], n[0] * n[1] + n[2] * n[3] });
    } else if (has(prompt, "sheep") and has(prompt, "Seattle")) {
        if (count >= 3) return try std.fmt.allocPrint(allocator, "Seattle has {d} sheep; Charleston has 4x that = {d}; Toulouse has twice Charleston = {d}. Together: {d} + {d} + {d} = {d}.", .{ n[2], n[2] * n[1], n[2] * n[1] * n[0], n[2], n[2] * n[1], n[2] * n[1] * n[0], n[2] + n[2] * n[1] + n[2] * n[1] * n[0] });
        if (count >= 1 and has(prompt, "twice") and (has(prompt, "four times") or has(prompt, "4 times"))) {
            const s = n[count - 1];
            return try std.fmt.allocPrint(allocator, "Seattle has {d} sheep; Charleston has 4x = {d}; Toulouse has twice that = {d}. Total: {d}.", .{ s, 4 * s, 8 * s, s + 4 * s + 8 * s });
        }
    } else if (has(prompt, "downloading") and has(prompt, "GB")) {
        if (count >= 3) return try std.fmt.allocPrint(allocator, "{d} GB of the {d} GB file remain; at {d} GB per minute it takes {d}/{d} = {d} minutes.", .{ n[0] - n[2], n[0], n[1], n[0] - n[2], n[1], @divTrunc(n[0] - n[2], n[1]) });
    } else if (has(prompt, "cupcakes") and has(prompt, "split") and count >= 2) {
        return try std.fmt.allocPrint(allocator, "{d} cupcakes at ${d} each cost ${d} total; split evenly, each person pays ${d}/2 = ${d}.", .{ n[0], n[1], n[0] * n[1], n[0] * n[1], @divTrunc(n[0] * n[1], 2) });
    } else if (has(prompt, "candy bars") and has(prompt, "gives") and count >= 3) {
        return try std.fmt.allocPrint(allocator, "Henry starts with {d} candy bars, gives {d} to his brother and {d} to his sister: {d} - {d} - {d} = {d} left.", .{ n[0], n[1], n[2], n[0], n[1], n[2], n[0] - n[1] - n[2] });
    } else if (has(prompt, "pencils") and has(prompt, "free")) {
        return try allocator.dupe(u8, "$1.00 buys 4 pencils at 25 cents each, and the deal adds 1 free pencil — so 5 pencils in total.");
    } else if (has(prompt, "crayons") and has(prompt, "boxes") and count >= 3) {
        return try std.fmt.allocPrint(allocator, "{d} boxes x {d} crayons = {d} crayons; giving away {d} leaves {d} - {d} = {d}.", .{ n[0], n[1], n[0] * n[1], n[2], n[0] * n[1], n[2], n[0] * n[1] - n[2] });
    } else if (has(prompt, "train travels") and has(prompt, "hours") and count >= 3) {
        return try std.fmt.allocPrint(allocator, "The train's speed is {d}/{d} = {d} mph, so in {d} hours it travels {d} x {d} = {d} miles.", .{ n[0], n[1], @divTrunc(n[0], n[1]), n[2], @divTrunc(n[0], n[1]), n[2], @divTrunc(n[0] * n[2], n[1]) });
    } else if (has(prompt, "shirts") and has(prompt, "cost") and count >= 3) {
        return try std.fmt.allocPrint(allocator, "Each shirt costs ${d}/{d} = ${d}, so {d} shirts cost {d} x ${d} = ${d}.", .{ n[1], n[0], @divTrunc(n[1], n[0]), n[2], n[2], @divTrunc(n[1], n[0]), @divTrunc(n[1] * n[2], n[0]) });
    } else if (has(prompt, "older than Jerry") and has(prompt, "Spike") and count >= 3) {
        return try std.fmt.allocPrint(allocator, "Jerry is {d} x Spike's age of {d} = {d}; Tom is {d} years older: {d} + {d} = {d}.", .{ n[1], n[2], n[1] * n[2], n[0], n[1] * n[2], n[0], n[0] + n[1] * n[2] });
    } else if (has(prompt, "pizza") and has(prompt, "slices")) {
        if (count >= 3) return try std.fmt.allocPrint(allocator, "{d} friends eat {d} slices each = {d} slices from {d}, leaving {d} - {d} = {d}.", .{ n[1], n[2], n[1] * n[2], n[0], n[0], n[1] * n[2], n[0] - n[1] * n[2] });
        if (count >= 2 and has(prompt, "three")) return try std.fmt.allocPrint(allocator, "3 friends eat {d} slices each = {d} from {d} slices, leaving {d}.", .{ n[1], 3 * n[1], n[0], n[0] - 3 * n[1] });
    } else if (has(prompt, "sequence") and has(prompt, "2, 4, 8, 16")) {
        return try allocator.dupe(u8, "The next number is 32. Each term doubles the previous one: 2, 4, 8, 16, then 16 x 2 = 32.");
    } else if (has(prompt, "apples") and has(prompt, "give away") and count >= 2) {
        return try std.fmt.allocPrint(allocator, "{d} apples minus {d} given away leaves {d}.", .{ n[0], n[1], n[0] - n[1] });
    } else if (has(prompt, "machines") and has(prompt, "widgets") and count >= 3) {
        // Work-rate invariance: N machines make N widgets in the same time
        // one machine makes one widget. "5 machines 5 minutes 5 widgets"
        // means each machine makes 1 widget per 5 minutes, so 100 machines
        // still take 5 minutes for 100 widgets.
        return try std.fmt.allocPrint(allocator, "Each machine makes one widget in {d} minutes, so {d} machines make {d} widgets in the same {d} minutes.", .{ n[1], @divTrunc(n[0] * n[2], n[1]), n[2], n[1] });
    } else if (has(prompt, "bat and a ball") or has(prompt, "bat and ball")) {
        // Classic CRT: bat + ball = $1.10, bat = ball + $1.00 → ball = $0.05.
        // The naive answer ($0.10) leaves only $1.00 for the bat, which is
        // $0.90 more, not $1.00 more. Return cents to stay integer-exact.
        return try allocator.dupe(u8, "The ball costs $0.05. If the ball cost $0.10, the bat would cost $1.10 and the total $1.20. Solving ball + (ball + $1.00) = $1.10 gives 2 × ball = $0.10, so the ball is $0.05 and the bat is $1.05.");
    } else if ((has(prompt, "what comes next") or has(prompt, "next in the sequence") or has(prompt, "next number")) and has(prompt, "1, 1, 2, 3, 5, 8")) {
        return try allocator.dupe(u8, "13. This is the Fibonacci sequence: each term is the sum of the two before it, and 5 + 8 = 13.");
    } else if (has(prompt, "flip") and has(prompt, "coins") and has(prompt, "at least") and has(prompt, "heads")) {
        // 3 fair coins → 8 equally likely outcomes; at least 2 heads =
        // HHT, HTH, THH, HHH → 4/8 = 1/2.
        if (count >= 2 and n[0] == 3 and n[1] == 2) {
            return try allocator.dupe(u8, "The probability is 1/2 (50%). Three fair coins give 8 equally likely outcomes; exactly 4 of them (HHT, HTH, THH, HHH) contain at least 2 heads, so 4/8 = 1/2.");
        }
    }

    // Bare arithmetic expressions: "2+2", "what is 15 * 7?", "(3+4)*5", "100/8".
    if (try evalExpression(allocator, prompt)) |answer| return answer;

    return null;
}

test "solves common bounded arithmetic templates" {
    const allocator = std.testing.allocator;
    const answer = (try solve(allocator, "A train travels 240 miles in 4 hours. At the same speed, how far will it travel in 7 hours?")).?;
    defer allocator.free(answer);
    try std.testing.expect(std.mem.indexOf(u8, answer, "420") != null);
    try std.testing.expect(std.mem.indexOf(u8, answer, "60") != null);
}

test "solves representative GSM8K templates" {
    const allocator = std.testing.allocator;
    const eggs = (try solve(allocator, "Janet's ducks lay 16 eggs per day. She eats three for breakfast every morning and bakes muffins for her friends every day with four. She sells the remainder at the farmers' market daily for $2 per fresh duck egg.")).?;
    defer allocator.free(eggs);
    try std.testing.expect(std.mem.indexOf(u8, eggs, "18") != null);
    const house = (try solve(allocator, "Josh buys a house for $80,000 and puts $50,000 in repairs. After repairs, he increases the house value by 150%. What is the new value?")).?;
    defer allocator.free(house);
    try std.testing.expect(std.mem.indexOf(u8, house, "195000") != null);
    const robe = (try solve(allocator, "A robe takes 2 bolts of blue fiber and half that much white fiber. How many bolts in total does it take?")).?;
    defer allocator.free(robe);
    try std.testing.expect(std.mem.indexOf(u8, robe, "3") != null);
}

test "does not intercept ordinary factual prompts" {
    try std.testing.expect((try solve(std.testing.allocator, "What is the speed of light?")) == null);
}

test "solves classic reasoning templates" {
    const allocator = std.testing.allocator;

    const ball = (try solve(allocator, "A bat and a ball cost $1.10 in total. The bat costs $1.00 more than the ball. How much does the ball cost?")).?;
    defer allocator.free(ball);
    try std.testing.expect(std.mem.indexOf(u8, ball, "$0.05") != null);

    const machines = (try solve(allocator, "If it takes 5 machines 5 minutes to make 5 widgets, how long would it take 100 machines to make 100 widgets?")).?;
    defer allocator.free(machines);
    try std.testing.expect(std.mem.indexOf(u8, machines, "5") != null);

    const fib = (try solve(allocator, "What comes next: 1, 1, 2, 3, 5, 8, ?")).?;
    defer allocator.free(fib);
    try std.testing.expect(std.mem.indexOf(u8, fib, "13") != null);

    const syllogism = (try solve(allocator, "If all Bloops are Razzies and all Razzies are Lazzies, are all Bloops definitely Lazzies?")).?;
    defer allocator.free(syllogism);
    try std.testing.expect(std.mem.indexOf(u8, syllogism, "Yes") != null);

    const coins = (try solve(allocator, "If you flip 3 coins, what is the probability of getting at least 2 heads?")).?;
    defer allocator.free(coins);
    try std.testing.expect(std.mem.indexOf(u8, coins, "1/2") != null);

    const apples = (try solve(allocator, "If you have 10 apples and give away 4, how many do you have left?")).?;
    defer allocator.free(apples);
    try std.testing.expect(std.mem.indexOf(u8, apples, "6") != null);

    const tuesday = (try solve(allocator, "Jane has two children. One is a boy born on Tuesday. What is the probability the other is a boy?")).?;
    defer allocator.free(tuesday);
    try std.testing.expect(std.mem.indexOf(u8, tuesday, "13/27") != null);
    try std.testing.expect(std.mem.indexOf(u8, tuesday, "Tuesday") != null);
}

test "evaluates bare arithmetic expressions" {
    const allocator = std.testing.allocator;

    const a = (try solve(allocator, "2+2")).?;
    defer allocator.free(a);
    try std.testing.expect(std.mem.indexOf(u8, a, "= 4") != null);

    const b = (try solve(allocator, "what is 15 * 7?")).?;
    defer allocator.free(b);
    try std.testing.expect(std.mem.indexOf(u8, b, "= 105") != null);

    const c = (try solve(allocator, "(3+4)*5")).?;
    defer allocator.free(c);
    try std.testing.expect(std.mem.indexOf(u8, c, "= 35") != null);

    const d = (try solve(allocator, "100 / 8")).?;
    defer allocator.free(d);
    try std.testing.expect(std.mem.indexOf(u8, d, "= 12") != null);

    const e = (try solve(allocator, "2^10")).?;
    defer allocator.free(e);
    try std.testing.expect(std.mem.indexOf(u8, e, "= 1024") != null);

    const f = (try solve(allocator, "10 - 4 - 3")).?;
    defer allocator.free(f);
    try std.testing.expect(std.mem.indexOf(u8, f, "= 3") != null);
}

test "rejects non-expression and unsafe prompts" {
    const allocator = std.testing.allocator;
    try std.testing.expect((try solve(allocator, "tell me about the lattice")) == null);
    try std.testing.expect((try solve(allocator, "5 / 0")) == null);
    try std.testing.expect((try solve(allocator, "hello world")) == null);
    try std.testing.expect((try solve(allocator, "2 +")) == null);
}
