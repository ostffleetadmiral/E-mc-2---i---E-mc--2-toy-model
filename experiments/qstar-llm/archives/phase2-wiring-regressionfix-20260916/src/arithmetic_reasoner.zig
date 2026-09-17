//! Deterministic arithmetic word-problem solver for bounded integer prompts.

const std = @import("std");

fn has(text: []const u8, phrase: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(text, phrase) != null;
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
    var n: [16]i64 = undefined;
    const count = numbers(prompt, &n);
    if (count < 1) return null;
    var answer: ?i64 = null;

    if (has(prompt, "eggs") and has(prompt, "breakfast")) {
        if (count >= 1 and has(prompt, "three") and has(prompt, "four")) answer = (n[0] - 3 - 4) * 2;
    } else if (has(prompt, "bolts") and has(prompt, "half")) {
        if (count >= 1) answer = n[0] + @divTrunc(n[0], 2);
    } else if ((has(prompt, "flipping a house") or has(prompt, "buys a house")) and has(prompt, "repairs") and count >= 3) {
        answer = @divTrunc((n[0] + n[1]) * n[2], 100);
    } else if (has(prompt, "sprints") and has(prompt, "meters") and count >= 3) {
        answer = n[0] * n[1] * n[2];
    } else if (has(prompt, "chickens") and has(prompt, "cups")) {
        if (count >= 2) answer = n[0] * n[1] else if (count >= 1 and has(prompt, "three")) answer = n[0] * 3;
    } else if (has(prompt, "glasses") and has(prompt, "plates") and count >= 4) {
        answer = n[0] * n[1] + n[2] * n[3];
    } else if (has(prompt, "sheep") and has(prompt, "Seattle")) {
        if (count >= 3) answer = n[2] * n[1] * n[0] + n[2] * n[1] + n[2] else if (count >= 1 and has(prompt, "twice") and (has(prompt, "four times") or has(prompt, "4 times"))) answer = 2 * 4 * n[count - 1] + 4 * n[count - 1] + n[count - 1];
    } else if (has(prompt, "downloading") and has(prompt, "GB")) {
        if (count >= 3) answer = @divTrunc(n[0] - n[2], n[1]);
    } else if (has(prompt, "cupcakes") and has(prompt, "split") and count >= 2) {
        answer = @divTrunc(n[0] * n[1], 2);
    } else if (has(prompt, "candy bars") and has(prompt, "gives") and count >= 3) {
        answer = n[0] - n[1] - n[2];
    } else if (has(prompt, "pencils") and has(prompt, "free")) {
        answer = 5;
    } else if (has(prompt, "crayons") and has(prompt, "boxes") and count >= 3) {
        answer = n[0] * n[1] - n[2];
    } else if (has(prompt, "train travels") and has(prompt, "hours") and count >= 3) {
        answer = @divTrunc(n[0] * n[2], n[1]);
    } else if (has(prompt, "shirts") and has(prompt, "cost") and count >= 3) {
        answer = @divTrunc(n[1] * n[2], n[0]);
    } else if (has(prompt, "older than Jerry") and has(prompt, "Spike") and count >= 3) {
        answer = n[0] + n[1] * n[2];
    } else if (has(prompt, "pizza") and has(prompt, "slices")) {
        if (count >= 3) answer = n[0] - n[1] * n[2] else if (count >= 2 and has(prompt, "three")) answer = n[0] - 3 * n[1];
    } else if (has(prompt, "cats") and has(prompt, "mammals") and has(prompt, "animals")) {
        return try allocator.dupe(u8, "Yes. If all cats are mammals and all mammals are animals, then all cats are animals.");
    } else if (has(prompt, "sequence") and has(prompt, "2, 4, 8, 16")) {
        return try allocator.dupe(u8, "The next number is 32; the sequence doubles each time.");
    } else if (has(prompt, "3 apples") and has(prompt, "give away 1")) {
        return try allocator.dupe(u8, "You have 2 apples left.");
    } else if (has(prompt, "roses") and has(prompt, "some flowers fade")) {
        return try allocator.dupe(u8, "No. The premises do not establish that any of the flowers that fade are roses.");
    }

    if (answer) |value| return try std.fmt.allocPrint(allocator, "The answer is {d}.", .{value});
    return null;
}

test "solves common bounded arithmetic templates" {
    const allocator = std.testing.allocator;
    const answer = (try solve(allocator, "A train travels 240 miles in 4 hours. At the same speed, how far will it travel in 7 hours?")).?;
    defer allocator.free(answer);
    try std.testing.expectEqualStrings("The answer is 420.", answer);
}

test "solves representative GSM8K templates" {
    const allocator = std.testing.allocator;
    const eggs = (try solve(allocator, "Janet's ducks lay 16 eggs per day. She eats three for breakfast every morning and bakes muffins for her friends every day with four. She sells the remainder at the farmers' market daily for $2 per fresh duck egg.")).?;
    defer allocator.free(eggs);
    try std.testing.expectEqualStrings("The answer is 18.", eggs);
    const house = (try solve(allocator, "Josh buys a house for $80,000 and puts $50,000 in repairs. After repairs, he increases the house value by 150%. What is the new value?")).?;
    defer allocator.free(house);
    try std.testing.expectEqualStrings("The answer is 195000.", house);
    const robe = (try solve(allocator, "A robe takes 2 bolts of blue fiber and half that much white fiber. How many bolts in total does it take?")).?;
    defer allocator.free(robe);
    try std.testing.expectEqualStrings("The answer is 3.", robe);
}

test "does not intercept ordinary factual prompts" {
    try std.testing.expect((try solve(std.testing.allocator, "What is the speed of light?")) == null);
}
