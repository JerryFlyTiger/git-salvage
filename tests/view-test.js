// Tests for the pure page logic of bin/git-salvage-view.html (the block
// between BEGIN LOGIC / END LOGIC). tests/run.sh concatenates that block and
// this file and runs the result with `node`, or `osascript -l JavaScript`.
// Output: one `ok <name>` / `not ok <name>` line per test, then `done <N>`.
// Under node it is written to stdout; under JXA it is the value of the last
// expression (JXA's console.log goes to stderr).
// Messages and status lines are copied from real git output
// (dev/measure-reflog.sh, and `status --porcelain=v2 --branch --show-stash`).

var OUT = [], NTESTS = 0;
function same(a, b) { return JSON.stringify(a) === JSON.stringify(b); }
function test(name, fn) {
	NTESTS++;
	var ok;
	try { ok = fn() === true; } catch (e) { ok = false; OUT.push("# " + name + ": " + e); }
	OUT.push((ok ? "ok " : "not ok ") + name);
}
function eq(a, b) {
	if (same(a, b)) return true;
	OUT.push("#   got      " + JSON.stringify(a));
	OUT.push("#   expected " + JSON.stringify(b));
	return false;
}
function rec() { return Array.prototype.slice.call(arguments).join("\0"); }
var A = "1111111111111111111111111111111111111111";
var B = "2222222222222222222222222222222222222222";
var C = "3333333333333333333333333333333333333333";
var D = "4444444444444444444444444444444444444444";

// ------------------------------------------------------------------ parseData

var DATA = [
	rec("V", "1"),
	rec("M", "my repo", "1790000000", "git version 2.55.0"),
	rec("H", "refs/heads/main", A),
	rec("S", "# branch.head main"),
	rec("R", "refs/heads/main", A, "", "refs/remotes/origin/main", "ahead 1"),
	rec("R", "refs/tags/v1", D, B, "", ""),
	rec("L", "HEAD@{1790000005}", A, "commit: a </script> \"q\" \u00e9\u4e2d"),
	rec("L", "refs/heads/main@{1790000005}", A, "commit: a"),
	rec("C", A, B + " " + C, "1790000005", "Ann Lee", "merge it"),
	rec("C", C, "", "1790000001", "Bo", "root"),
	rec("P", "refs/salvage/1790000009-000001-0000000042", D, "1790000009", "git reset --hard",
		A + " " + B, "Salvage-Kind: worktree\u001fSalvage-Head: refs/heads/main"),
	rec("P", "refs/salvage/1790000009-000000-0000000042", C, "1790000009", "git branch -D x",
		B, "Salvage-Kind: branch\u001fSalvage-Ref: refs/heads/x"),
	rec("P", "refs/salvage/1790000001-000000-0000000042", C, "1790000001", "odd", "", ""),
	""
].join("\n");

test("parseData: version, meta, head", function () {
	var d = parseData(DATA);
	return eq([d.version, d.meta, d.head],
		["1", { repo: "my repo", time: 1790000000, git: "git version 2.55.0" }, { ref: "refs/heads/main", id: A }]);
});
test("parseData: status lines kept whole", function () {
	return eq(parseData(DATA).status, ["# branch.head main"]);
});
test("parseData: refs with peeled tag and tracking", function () {
	return eq(parseData(DATA).refs, [
		{ name: "refs/heads/main", id: A, peeled: "", upstream: "refs/remotes/origin/main", track: "ahead 1" },
		{ name: "refs/tags/v1", id: D, peeled: B, upstream: "", track: "" }]);
});
test("parseData: reflog ref and time split from %gD; message kept byte-exact", function () {
	var r = parseData(DATA).reflog;
	return eq(r, [
		{ ref: "HEAD", time: 1790000005, id: A, msg: "commit: a </script> \"q\" \u00e9\u4e2d" },
		{ ref: "refs/heads/main", time: 1790000005, id: A, msg: "commit: a" }]);
});
test("parseData: commits with 2 and 0 parents", function () {
	return eq(parseData(DATA).commits, [
		{ id: A, parents: [B, C], time: 1790000005, author: "Ann Lee", subject: "merge it" },
		{ id: C, parents: [], time: 1790000001, author: "Bo", subject: "root" }]);
});
test("parseData: snapshots numbered by order, 1 = newest; first parent; trailers", function () {
	var s = parseData(DATA).snapshots;
	return eq(s.map(function (x) { return [x.n, x.kind, x.parent, x.about, x.time, x.subject]; }), [
		[1, "worktree", A, "refs/heads/main", 1790000009, "git reset --hard"],
		[2, "branch", B, "refs/heads/x", 1790000009, "git branch -D x"],
		[3, "", "", "", 1790000001, "odd"]]);
});
test("parseData: no trailing newline, unknown tag ignored", function () {
	var d = parseData(rec("V", "1") + "\n" + rec("Z", "x") + "\n" + rec("H", "", ""));
	return eq([d.version, d.head, d.snapshots.length], ["1", { ref: "", id: "" }, 0]);
});

// ---------------------------------------------------------------- parseStatus

var H1 = "78981922613b2afb6025042ff6bd878ac1994e85", H2 = "93829c7b4af9dfbeea3b31395b042a614d7a190d";
test("parseStatus: branch header, ahead/behind, stash", function () {
	var s = parseStatus(["# branch.oid " + A, "# branch.head main", "# branch.upstream origin/main",
		"# branch.ab +1 -2", "# stash 3"]);
	return eq([s.oid, s.branch, s.upstream, s.ahead, s.behind, s.hasAb, s.stash],
		[A, "main", "origin/main", 1, 2, true, 3]);
});
test("parseStatus: gone upstream has no branch.ab", function () {
	var s = parseStatus(["# branch.head t", "# branch.upstream origin/gone"]);
	return eq([s.upstream, s.hasAb, s.ahead, s.behind], ["origin/gone", false, 0, 0]);
});
test("parseStatus: type 1 staged / modified / both, path with spaces", function () {
	var s = parseStatus([
		"1 M. N... 100644 100644 100644 " + H1 + " " + H2 + " with space",
		"1 .M N... 100644 100644 100644 " + H1 + " " + H1 + " a  b",
		"1 MM N... 100644 100644 100644 " + H1 + " " + H2 + " f"]);
	return eq([s.staged, s.modified], [["with space", "f"], ["a  b", "f"]]);
});
test("parseStatus: type 2 rename takes the new path", function () {
	var s = parseStatus(["2 R. N... 100644 100644 100644 " + H1 + " " + H1 + " R100 new name\told name"]);
	return eq([s.staged, s.modified], [["new name"], []]);
});
test("parseStatus: unmerged and untracked (spaces, quoted non-ASCII)", function () {
	var s = parseStatus([
		"u UU N... 100644 100644 100644 100644 " + H1 + " " + H2 + " " + H1 + " conf file",
		"? un tracked", "? \"caf\\303\\251\""]);
	return eq([s.conflicted, s.untracked, s.staged, s.modified],
		[["conf file"], ["un tracked", "\"caf\\303\\251\""], [], []]);
});
test("parseStatus: ignored lines are not counted", function () {
	var s = parseStatus(["! build/"]);
	return eq([s.staged.length, s.modified.length, s.untracked.length, s.conflicted.length], [0, 0, 0, 0]);
});

// ---------------------------------------------------------------- buildEvents

function L(ref, time, id, msg) { return { ref: ref, time: time, id: id, msg: msg }; }
test("buildEvents: HEAD and branch entry of one commit are one event", function () {
	var ev = buildEvents([
		L("HEAD", 20, B, "commit: b"), L("refs/heads/main", 20, B, "commit: b"),
		L("HEAD", 10, A, "commit (initial): a"), L("refs/heads/main", 10, A, "commit (initial): a")], []);
	return eq(ev.map(function (e) { return [e.msg, e.old, e.id, e.moves.map(function (m) { return m.ref; })]; }), [
		["commit: b", A, B, ["HEAD", "refs/heads/main"]],
		["commit (initial): a", null, A, ["HEAD", "refs/heads/main"]]]);
});
test("buildEvents: old id is the same ref's next-older entry", function () {
	var ev = buildEvents([
		L("refs/heads/f", 30, C, "branch: Reset to HEAD~2"),
		L("HEAD", 25, B, "checkout: moving from f to main"),
		L("refs/heads/f", 5, A, "branch: Created from main")], []);
	return eq(ev.map(function (e) { return [e.time, e.old, e.id]; }), [[30, A, C], [25, null, B], [5, null, A]]);
});
test("buildEvents: same message but different time is not merged", function () {
	var ev = buildEvents([L("HEAD", 11, A, "commit: a"), L("refs/heads/main", 10, A, "commit: a")], []);
	return eq(ev.map(function (e) { return e.moves.length; }), [1, 1]);
});
test("buildEvents: snapshots sort by time, and after the same second's reflog entries", function () {
	var snaps = [{ n: 1, time: 50, parent: A }, { n: 2, time: 50, parent: B }, { n: 3, time: 30, parent: C }];
	var ev = buildEvents([
		L("HEAD", 60, D, "commit: later"),
		L("HEAD", 50, A, "reset: moving to HEAD~1"),
		L("HEAD", 50, B, "commit: same second"),
		L("HEAD", 40, C, "commit: before")], snaps);
	return eq(ev.map(function (e) { return e.type === "snapshot" ? "s" + e.snap.n : e.msg; }),
		["commit: later", "reset: moving to HEAD~1", "commit: same second", "s1", "s2", "commit: before", "s3"]);
});
test("buildEvents: snapshot event points at its first parent", function () {
	var ev = buildEvents([], [{ n: 1, time: 5, parent: A }]);
	return eq([ev[0].id, ev[0].old, ev[0].moves], [A, null, []]);
});

// -------------------------------------------------------------------- explain

function says(msg, ref, branches, needle) {
	var t = explain(msg, ref, branches).text;
	if (t !== null && t.indexOf(needle) >= 0) return true;
	OUT.push("#   " + JSON.stringify(msg) + " -> " + JSON.stringify(t));
	return false;
}
var BR = { main: true, feature: true, topic: true, side: true, b2: true };
// Every message dev/measure-reflog.sh printed, with a word its text must have.
var MEASURED = [
	["HEAD", "commit (initial): one", "very first commit"],
	["HEAD", "commit: two", "new commit \u201ctwo\u201d"],
	["HEAD", "checkout: moving from main to feature", "to the branch feature"],
	["HEAD", "merge feature: Merge made by the 'ort' strategy.", "Merged feature with a new merge commit"],
	["refs/heads/main", "reset: moving to HEAD~1", "Moved the current branch (and HEAD) to HEAD~1"],
	["HEAD", "rebase (start): checkout feature", "Rebase started"],
	["HEAD", "rebase (pick): three", "Copied the commit \u201cthree\u201d onto the new base"],
	["HEAD", "rebase (finish): returning to refs/heads/topic", "Rebase finished"],
	["refs/heads/topic", "rebase (finish): refs/heads/topic onto " + A, "Rebase finished"],
	["HEAD", "cherry-pick: s1", "Copied the commit \u201cs1\u201d"],
	["HEAD", "revert: Revert \"s1\"", "undoes an earlier one"],
	["HEAD", "commit (amend): revert amended", "Replaced the last commit"],
	["HEAD", "checkout: moving from main to HEAD~1", "detached"],
	["HEAD", "checkout: moving from " + A + " to main", "Switched from 1111111 to the branch main"],
	["HEAD", "reset: moving to HEAD", "git stash"],
	["HEAD", "merge main: Fast-forward", "Merged main as a fast-forward"],
	["HEAD", "pull -q --rebase origin main (start): checkout " + A, "pull --rebase started"],
	["HEAD", "pull -q --rebase origin main (pick): local1", "Copied the commit \u201clocal1\u201d"],
	["HEAD", "pull -q --rebase origin main (finish): returning to refs/heads/main", "Rebase finished"],
	["HEAD", "pull -q --no-rebase --no-edit origin main: Merge made by the 'ort' strategy.", "Pulled and merged"],
	["HEAD", "pull -q --ff-only: Fast-forward", "(fast-forward)"],
	["refs/heads/feature", "branch: Created from main", "Created this branch at main"],
	["refs/heads/feature", "branch: Reset to HEAD~2", "Moved this branch by force to HEAD~2"],
	["refs/remotes/origin/main", "update by push", "You pushed"],
	["refs/remotes/origin/main", "fetch -q origin: fast-forward", "Downloaded new commits"],
	["refs/remotes/origin/main", "pull -q --no-rebase --no-edit origin main: fast-forward", "Downloaded new commits"],
	["refs/remotes/origin/main", "pull -q --ff-only: fast-forward", "Downloaded new commits"],
	["refs/heads/b2", "Branch: renamed refs/heads/b to refs/heads/b2", "Renamed the branch b to b2"],
	["HEAD", "rebase (abort): returning to refs/heads/b2", "Rebase cancelled"],
	["HEAD", "commit (merge): Merge branch 'b2'", "Finished a merge"],
	["HEAD", "clone: from /tmp/x/q5", "Cloned the repository from /tmp/x/q5"]
];
MEASURED.forEach(function (m) {
	test("explain: " + m[1], function () { return says(m[1], m[0], BR, m[2]); });
});
test("explain: no branch entry, nothing said about a branch or detaching", function () {
	// A HEAD-only entry may be a detached HEAD, or a branch whose reflog is
	// gone (deleted branch, Q4): the text must fit both.
	var cases = [["commit: x", "Made a new commit \u201cx\u201d."], ["reset: moving to HEAD~1", "Moved HEAD to HEAD~1"],
		["merge main: Fast-forward", "HEAD just moved ahead"], ["cherry-pick: s1", "onto HEAD,"],
		["pull -q --ff-only: Fast-forward", "Pulled: HEAD moved forward"],
		["rebase (finish): returning to refs/heads/topic", "Rebase finished: HEAD now points"]];
	return cases.every(function (c) {
		var t = explain(c[0], "HEAD", BR, false).text;
		if (t.indexOf(c[1]) >= 0 && !/branch|detached/.test(t.replace(/Merged main/, ""))) return true;
		OUT.push("#   " + JSON.stringify(c[0]) + " -> " + JSON.stringify(t));
		return false;
	});
});
test("explain: reset makes no claim about what was left behind", function () {
	// A reset can move forward (to origin/main) or nowhere: the page's own
	// reachability note says what is left behind, not this text.
	return explain("reset: moving to origin/main", "refs/heads/main", BR, true).text.indexOf("left behind") < 0;
});
test("explain: checkout to a name that is not a local branch is not called a branch", function () {
	var t = explain("checkout: moving from main to v1.0", "HEAD", BR).text;
	return eq([t.indexOf("branch") < 0, t.indexOf("v1.0") >= 0], [true, true]);
});
test("explain: checkout with no branch list does not guess a branch", function () {
	return explain("checkout: moving from main to feature", "HEAD", undefined).text.indexOf("the branch") < 0;
});
test("explain: action, phase and detail are split", function () {
	var r = explain("pull -q --rebase origin main (pick): local1", "HEAD", BR);
	return eq([r.action, r.phase, r.detail], ["pull", "pick", "local1"]);
});
test("explain: unknown messages give text null", function () {
	var unknown = [["HEAD", "stash: whatever"], ["HEAD", "commit (weird): x"], ["HEAD", "merge x: Something new"],
		["HEAD", "no colon here"], ["refs/remotes/origin/main", "fetch origin: forced-update"],
		["refs/remotes/origin/main", "commit: x"], ["refs/heads/main", "branch: something else"],
		["HEAD", "rebase (continue): x"], ["HEAD", "pull origin main: Already up to date"],
		["HEAD", "cherry-pick (x): s1"], ["HEAD", "revert (y): Revert \"s1\""], ["HEAD", "clone (z): from /x"],
		["HEAD", "clone: somewhere"]];
	return unknown.every(function (u) {
		var t = explain(u[1], u[0], BR).text;
		if (t === null) return true;
		OUT.push("#   " + JSON.stringify(u[1]) + " -> " + JSON.stringify(t));
		return false;
	});
});

test("eventRef: the local branch of a merged event, even after a remote ref", function () {
	return eq([eventRef([{ ref: "HEAD" }, { ref: "refs/remotes/origin/main" }, { ref: "refs/heads/main" }]),
		eventRef([{ ref: "HEAD" }]), eventRef([{ ref: "refs/remotes/origin/main" }]), eventRef([])],
		["refs/heads/main", "HEAD", "refs/remotes/origin/main", ""]);
});
test("explain via eventRef: a clone event keeps its explanation", function () {
	var moves = [{ ref: "HEAD" }, { ref: "refs/remotes/origin/main" }, { ref: "refs/heads/main" }];
	return says("clone: from /x", eventRef(moves), BR, "Cloned the repository from /x");
});
test("movesBranch: HEAD-only is detached", function () {
	return eq([movesBranch([{ ref: "HEAD" }]), movesBranch([{ ref: "HEAD" }, { ref: "refs/heads/main" }]),
		movesBranch([{ ref: "refs/remotes/origin/main" }])], [false, true, false]);
});
test("buildEvents: two equal HEAD entries in one second stay two events", function () {
	var ev = buildEvents([
		L("HEAD", 7, A, "reset: moving to HEAD"), L("HEAD", 7, A, "reset: moving to HEAD"),
		L("refs/heads/main", 7, A, "reset: moving to HEAD"), L("refs/heads/main", 7, A, "reset: moving to HEAD")], []);
	return eq(ev.map(function (e) { return e.moves.map(function (m) { return m.ref; }); }),
		[["HEAD", "refs/heads/main"], ["HEAD", "refs/heads/main"]]);
});

// --------------------------------------------------------------- snapshotText

test("snapshotText: each kind, and no guess for an unknown one", function () {
	return eq([snapshotText({ kind: "worktree" }), snapshotText({ kind: "branch", about: "refs/heads/x" }),
		snapshotText({ kind: "stash", about: "stash@{0}" }), snapshotText({ kind: "", about: "" })],
		["Your uncommitted work was saved right before this command ran.",
			"The branch x was saved before it was deleted or overwritten.",
			"The stash entry stash@{0} was saved before it was removed.", "Saved by git-salvage."]);
});

// ------------------------------------------------------------------ reachable

var GRAPH = [ // date order, newest first: M merges A and B, both on O
	{ id: "M", parents: ["A", "B"] }, { id: "A", parents: ["O"] }, { id: "B", parents: ["O"] },
	{ id: "X", parents: ["O"] }, { id: "O", parents: ["P"] }];
function keys(o) { return Object.keys(o).sort(); }
test("reachable: through both parents of a merge", function () {
	return eq(keys(reachable(GRAPH, ["M"])), ["A", "B", "M", "O"]);
});
test("reachable: side commit and unloaded parent ignored", function () {
	return eq(keys(reachable(GRAPH, ["B", "", "nope"])), ["B", "O"]);
});
test("reachable: no tips, nothing", function () {
	return eq(keys(reachable(GRAPH, [])), []);
});

// --------------------------------------------------------------------- layout

function rows(cs) { return layout(cs).rows.map(function (r) { return [r.id, r.col, r.top, r.bottom]; }); }
test("layout: linear history uses one lane", function () {
	var l = layout([{ id: "c", parents: ["b"] }, { id: "b", parents: ["a"] }, { id: "a", parents: [] }]);
	return eq([l.width, rows([{ id: "c", parents: ["b"] }, { id: "b", parents: ["a"] }, { id: "a", parents: [] }])],
		[1, [["c", 0, [], [[0, 0]]], ["b", 0, [[0, 0]], [[0, 0]]], ["a", 0, [[0, 0]], []]]]);
});
test("layout: branch and merge", function () {
	var cs = [{ id: "M", parents: ["A", "B"] }, { id: "A", parents: ["O"] }, { id: "B", parents: ["O"] },
		{ id: "O", parents: [] }];
	return eq([layout(cs).width, rows(cs)], [2, [
		["M", 0, [], [[0, 0], [0, 1]]],
		["A", 0, [[0, 0], [1, 1]], [[0, 0], [1, 1]]],
		// O already has lane 0 when B reaches it: lane 0 passes B's row and
		// keeps its bottom segment, and B joins it.
		["B", 1, [[0, 0], [1, 1]], [[0, 0], [1, 0]]],
		["O", 0, [[0, 0]], []]]]);
});
test("layout: two tips side by side, lane freed after the root", function () {
	var cs = [{ id: "t1", parents: ["r"] }, { id: "t2", parents: [] }, { id: "r", parents: [] }];
	return eq([layout(cs).width, rows(cs)], [2, [
		["t1", 0, [], [[0, 0]]],
		["t2", 1, [[0, 0]], [[0, 0]]],
		["r", 0, [[0, 0]], []]]]);
});

test("layout: merge whose first parent already has a lane", function () {
	var cs = [{ id: "X", parents: ["P"] }, { id: "M", parents: ["P", "Q"] }, { id: "Q", parents: ["P"] },
		{ id: "P", parents: [] }];
	return eq([layout(cs).width, rows(cs)], [2, [
		["X", 0, [], [[0, 0]]],
		// M gets lane 1; P already has lane 0: lane 0 passes and M joins it,
		// Q takes M's freed lane.
		["M", 1, [[0, 0]], [[0, 0], [1, 0], [1, 1]]],
		["Q", 1, [[0, 0], [1, 1]], [[0, 0], [1, 0]]],
		["P", 0, [[0, 0]], []]]]);
});
test("layout: parent outside the loaded window keeps its lane to the bottom", function () {
	var cs = [{ id: "c", parents: ["gone"] }, { id: "d", parents: [] }];
	return eq([layout(cs).width, rows(cs)], [2, [
		["c", 0, [], [[0, 0]]],
		["d", 1, [[0, 0]], [[0, 0]]]]]);
});

// --------------------------------------------------------------- whereSentence

function st(lines) { return parseStatus(lines); }
test("whereSentence: unborn branch", function () {
	return eq(whereSentence(st(["# branch.oid (initial)", "# branch.head main"]), { ref: "refs/heads/main", id: "" }),
		"You are on branch main, which has no commits yet.");
});
test("whereSentence: unborn branch with an untracked file", function () {
	return eq(whereSentence(st(["# branch.oid (initial)", "# branch.head main", "? a"]), { ref: "refs/heads/main", id: "" }),
		"You are on branch main, which has no commits yet. 1 file is untracked.");
});
test("whereSentence: detached", function () {
	return eq(whereSentence(st(["# branch.oid " + A, "# branch.head (detached)"]), { ref: "", id: A }),
		"HEAD is detached at 1111111: you are on a commit, not on a branch. Nothing uncommitted.");
});
test("whereSentence: ahead and behind, staged + modified + conflicted + untracked", function () {
	var s = st(["# branch.head main", "# branch.upstream origin/main", "# branch.ab +1 -2",
		"1 MM N... 100644 100644 100644 " + H1 + " " + H2 + " f",
		"1 M. N... 100644 100644 100644 " + H1 + " " + H2 + " g",
		"u UU N... 100644 100644 100644 100644 " + H1 + " " + H2 + " " + H1 + " c",
		"? u1", "? u2"]);
	return eq(whereSentence(s, { ref: "refs/heads/main", id: A }),
		"You are on branch main, 1 commit ahead of and 2 commits behind origin/main. " +
		"1 file has merge conflicts, 2 changes are staged, 1 file is modified but not staged, 2 files are untracked.");
});
test("whereSentence: up to date", function () {
	return eq(whereSentence(st(["# branch.head main", "# branch.upstream origin/main", "# branch.ab +0 -0"]),
		{ ref: "refs/heads/main", id: A }),
		"You are on branch main, up to date with origin/main. Nothing uncommitted.");
});
test("whereSentence: only behind", function () {
	return eq(whereSentence(st(["# branch.head main", "# branch.upstream origin/main", "# branch.ab +0 -3"]),
		{ ref: "refs/heads/main", id: A }),
		"You are on branch main, 3 commits behind origin/main. Nothing uncommitted.");
});
test("whereSentence: gone upstream", function () {
	return eq(whereSentence(st(["# branch.head t", "# branch.upstream origin/gone"]), { ref: "refs/heads/t", id: A }),
		"You are on branch t (its upstream origin/gone is gone). Nothing uncommitted.");
});
test("whereSentence: no upstream", function () {
	return eq(whereSentence(st(["# branch.head main"]), { ref: "refs/heads/main", id: A }),
		"You are on branch main. Nothing uncommitted.");
});

OUT.push("done " + NTESTS);
var RESULT = OUT.join("\n");
if (typeof process !== "undefined" && process.stdout) process.stdout.write(RESULT + "\n");
RESULT;
