import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import {
  DAY_MS,
  LABELS,
  analyzeChecks,
  clearWaitingLabel,
  defaultCodeowners,
  evaluatePullRequest,
  formatAuthorCloseComment,
  formatAuthorNudgeComment,
  formatMaintainerReminderComment,
  isCommunityAuthor,
  readFollowupMarker,
  runSweep,
} from "./community-pr-followup.mjs";

const BASE_TIME = Date.parse("2026-11-26T09:23:00Z");
const daysAgo = (days) => new Date(BASE_TIME - days * DAY_MS).toISOString();

function makePR(overrides = {}) {
  return {
    number: 100,
    state: "OPEN",
    title: "fix: sample community change",
    isDraft: false,
    createdAt: daysAgo(10),
    mergeable: "MERGEABLE",
    authorAssociation: "FIRST_TIME_CONTRIBUTOR",
    author: { __typename: "User", login: "alice" },
    headRefOid: "abc1234",
    headRefName: "fix/sample",
    headRepository: "alice/StableBar",
    labels: [],
    requestedReviewers: ["Seb-GRAF"],
    headCommit: { oid: "abc1234", pushedDate: daysAgo(10), committedDate: daysAgo(10) },
    statusContexts: [
      { __typename: "CheckRun", name: "Test", status: "COMPLETED", conclusion: "SUCCESS", completedAt: daysAgo(10) },
    ],
    timelineDates: [],
    reviews: [],
    reviewThreads: [],
    comments: [],
    awaitingWorkflowApproval: false,
    ...overrides,
  };
}

function botComment(body, createdAt) {
  return { author: { __typename: "Bot", login: "github-actions" }, authorAssociation: "NONE", body, createdAt };
}

test("isCommunityAuthor excludes team members and bots", () => {
  assert.equal(isCommunityAuthor({ __typename: "User", login: "alice" }, "FIRST_TIME_CONTRIBUTOR"), true);
  assert.equal(isCommunityAuthor({ __typename: "User", login: "bob" }, "CONTRIBUTOR"), true);
  assert.equal(isCommunityAuthor({ __typename: "User", login: "carol" }, "NONE"), true);

  assert.equal(isCommunityAuthor({ __typename: "User", login: "Seb-GRAF" }, "OWNER"), false);
  assert.equal(isCommunityAuthor({ __typename: "User", login: "M4n0x" }, "COLLABORATOR"), false);
  assert.equal(isCommunityAuthor({ __typename: "User", login: "member" }, "MEMBER"), false);
  assert.equal(isCommunityAuthor({ __typename: "Bot", login: "dependabot" }, "NONE"), false);
  assert.equal(isCommunityAuthor({ type: "Bot", login: "github-actions[bot]" }, "NONE"), false);
  assert.equal(isCommunityAuthor(null, "NONE"), false);
});

test("defaultCodeowners parses wildcard user owners and matches the repository file", () => {
  assert.deepEqual(defaultCodeowners("# comment\n* @alice @bob @org/team\n/docs/ @carol\n"), ["alice", "bob"]);
  const repoCodeowners = readFileSync(new URL("../CODEOWNERS", import.meta.url), "utf8");
  assert.deepEqual(defaultCodeowners(), defaultCodeowners(repoCodeowners));
});

test("readFollowupMarker trusts only bot comments and prefers publication createdAt", () => {
  const body = formatAuthorNudgeComment({
    authorLogin: "alice",
    headSha: "abc1234",
    isDraft: false,
    blockers: [{ kind: "merge-conflicts" }],
    daysIdle: 7,
    closeInDays: 7,
    now: BASE_TIME - 60_000,
  });

  const publishedAt = new Date(BASE_TIME).toISOString();
  const parsed = readFollowupMarker(botComment(body, publishedAt));
  assert.equal(parsed?.kind, "author-nudge");
  assert.equal(parsed?.headSha, "abc1234");
  assert.equal(parsed?.draft, false);
  assert.equal(parsed?.at, BASE_TIME);

  const fallbackParsed = readFollowupMarker(botComment(body, null));
  assert.equal(fallbackParsed?.at, BASE_TIME - 60_000);

  assert.equal(readFollowupMarker({ author: { __typename: "User", login: "alice" }, body, createdAt: daysAgo(1) }), null);
});

test("analyzeChecks deduplicates reruns and classifies Visual review statuses", () => {
  const result = analyzeChecks([
    { __typename: "CheckRun", name: "Test", status: "COMPLETED", conclusion: "FAILURE", completedAt: daysAgo(2) },
    { __typename: "CheckRun", name: "Test", status: "COMPLETED", conclusion: "SUCCESS", completedAt: daysAgo(1) },
    { __typename: "CheckRun", name: "Description", status: "COMPLETED", conclusion: "FAILURE", completedAt: daysAgo(1) },
    { __typename: "StatusContext", context: "Visual review", state: "PENDING", description: "2 screens changed: a maintainer adds visual-ok after looking.", createdAt: daysAgo(1) },
  ]);
  assert.deepEqual(result, { failingChecks: ["Description"], visualReviewPending: true, baseChanged: false });

  const baseChanged = analyzeChecks([
    { __typename: "StatusContext", context: "Visual review", state: "PENDING", description: "The base changed: push a commit to compare the screens with it.", createdAt: daysAgo(1) },
  ]);
  assert.deepEqual(baseChanged, { failingChecks: [], visualReviewPending: false, baseChanged: true });

  const visualFailed = analyzeChecks([
    { __typename: "StatusContext", context: "Visual review", state: "FAILURE", description: "Drawing the screens failed: see the comment.", createdAt: daysAgo(1) },
  ]);
  assert.deepEqual(visualFailed, { failingChecks: ["Visual review"], visualReviewPending: false, baseChanged: false });
});

test("skips team PRs and PRs with keep-open", () => {
  assert.equal(evaluatePullRequest(makePR({ authorAssociation: "COLLABORATOR" }), { now: BASE_TIME }).reason, "not-community");
  assert.equal(evaluatePullRequest(makePR({ labels: [LABELS.keepOpen] }), { now: BASE_TIME }).reason, "keep-open");
});

test("ready PR waiting on author nudges at 7 days, waits before 14, and closes 7 days after nudge", () => {
  const failing = [
    { __typename: "CheckRun", name: "Description", status: "COMPLETED", conclusion: "FAILURE", completedAt: daysAgo(6) },
    { __typename: "CheckRun", name: "Test", status: "COMPLETED", conclusion: "FAILURE", completedAt: daysAgo(6) },
  ];

  const day6 = evaluatePullRequest(makePR({ createdAt: daysAgo(6), headCommit: { pushedDate: daysAgo(6) }, statusContexts: failing }), { now: BASE_TIME });
  assert.equal(day6.action, "none");
  assert.equal(day6.court, "author");

  const day7 = evaluatePullRequest(makePR({
    createdAt: daysAgo(7),
    headCommit: { pushedDate: daysAgo(7) },
    statusContexts: failing,
    mergeable: "CONFLICTING",
    labels: [LABELS.needsReview.name],
  }), { now: BASE_TIME });
  assert.equal(day7.action, "nudge-author");
  assert.deepEqual(day7.labelsToAdd, [LABELS.waitingForAuthor.name]);
  assert.deepEqual(day7.labelsToRemove, [LABELS.needsReview.name]);
  assert.deepEqual(day7.blockers, [
    { kind: "failing-checks", checks: ["Description", "Test"] },
    { kind: "merge-conflicts" },
  ]);

  const nudgeBody = formatAuthorNudgeComment({
    authorLogin: "alice",
    headSha: "abc1234",
    isDraft: false,
    blockers: day7.blockers,
    daysIdle: 7,
    closeInDays: 7,
    now: BASE_TIME - 6 * DAY_MS,
  });
  const day13 = evaluatePullRequest(makePR({
    createdAt: daysAgo(13),
    headCommit: { pushedDate: daysAgo(13) },
    statusContexts: failing,
    labels: [LABELS.waitingForAuthor.name],
    comments: [botComment(nudgeBody, daysAgo(6))],
  }), { now: BASE_TIME });
  assert.equal(day13.action, "wait");
  assert.equal(day13.reason, "already-nudged");

  const oldNudgeBody = formatAuthorNudgeComment({
    authorLogin: "alice",
    headSha: "abc1234",
    isDraft: false,
    blockers: day7.blockers,
    daysIdle: 7,
    closeInDays: 7,
    now: BASE_TIME - 7 * DAY_MS,
  });
  const day14 = evaluatePullRequest(makePR({
    createdAt: daysAgo(14),
    headCommit: { pushedDate: daysAgo(14) },
    statusContexts: failing,
    labels: [LABELS.waitingForAuthor.name],
    comments: [botComment(oldNudgeBody, daysAgo(7))],
  }), { now: BASE_TIME });
  assert.equal(day14.action, "close-author");
  assert.equal(day14.daysSinceNudge, 7);
});

test("nudge from an earlier headSha cannot authorize closing after a push with old commit dates", () => {
  const failing = [{ __typename: "CheckRun", name: "Test", status: "COMPLETED", conclusion: "FAILURE", completedAt: daysAgo(14) }];
  const oldNudge = formatAuthorNudgeComment({
    authorLogin: "alice",
    headSha: "old-head",
    isDraft: false,
    blockers: [{ kind: "failing-checks", checks: ["Test"] }],
    daysIdle: 7,
    closeInDays: 7,
    now: BASE_TIME - 7 * DAY_MS,
  });
  const readyAfterPush = evaluatePullRequest(makePR({
    headRefOid: "new-head",
    createdAt: daysAgo(14),
    headCommit: { oid: "new-head", committedDate: daysAgo(12), authoredDate: daysAgo(12) },
    statusContexts: failing,
    labels: [LABELS.waitingForAuthor.name],
    comments: [botComment(oldNudge, daysAgo(7))],
  }), { now: BASE_TIME });
  assert.equal(readyAfterPush.action, "nudge-author");

  const oldDraftNudge = formatAuthorNudgeComment({
    authorLogin: "alice",
    headSha: "old-head",
    isDraft: true,
    blockers: ["draft"],
    daysIdle: 14,
    closeInDays: 14,
    now: BASE_TIME - 14 * DAY_MS,
  });
  const draftAfterPush = evaluatePullRequest(makePR({
    isDraft: true,
    headRefOid: "new-head",
    createdAt: daysAgo(28),
    headCommit: { oid: "new-head", committedDate: daysAgo(20), authoredDate: daysAgo(20) },
    labels: [LABELS.waitingForAuthor.name],
    comments: [botComment(oldDraftNudge, daysAgo(14))],
  }), { now: BASE_TIME });
  assert.equal(draftAfterPush.action, "nudge-author");
});

test("bot comments do not reset the inactivity clock, while author comments and reopens do", () => {
  const failing = [{ __typename: "CheckRun", name: "Test", status: "COMPLETED", conclusion: "FAILURE", completedAt: daysAgo(8) }];
  const botNoise = { author: { __typename: "Bot", login: "coderabbitai" }, body: "rate limited", createdAt: daysAgo(1) };

  const withBotNoise = evaluatePullRequest(makePR({
    createdAt: daysAgo(8),
    headCommit: { pushedDate: daysAgo(8) },
    statusContexts: failing,
    comments: [botNoise],
  }), { now: BASE_TIME });
  assert.equal(withBotNoise.action, "nudge-author");

  const nudgeBody = formatAuthorNudgeComment({
    authorLogin: "alice",
    headSha: "abc1234",
    isDraft: false,
    blockers: [{ kind: "failing-checks", checks: ["Test"] }],
    daysIdle: 7,
    closeInDays: 7,
    now: BASE_TIME - 8 * DAY_MS,
  });
  const afterAuthorReply = evaluatePullRequest(makePR({
    createdAt: daysAgo(15),
    headCommit: { pushedDate: daysAgo(15) },
    statusContexts: failing,
    labels: [LABELS.waitingForAuthor.name],
    comments: [
      botComment(nudgeBody, daysAgo(8)),
      { author: { __typename: "User", login: "alice" }, authorAssociation: "FIRST_TIME_CONTRIBUTOR", body: "Working on it this weekend!", createdAt: daysAgo(2) },
    ],
  }), { now: BASE_TIME });
  assert.equal(afterAuthorReply.action, "none");
  assert.deepEqual(afterAuthorReply.labelsToRemove, [LABELS.waitingForAuthor.name]);

  const reopened = evaluatePullRequest(makePR({
    createdAt: daysAgo(30),
    headCommit: { pushedDate: daysAgo(30) },
    timelineDates: [daysAgo(1)],
    statusContexts: failing,
    labels: [LABELS.waitingForAuthor.name],
    comments: [botComment(nudgeBody, daysAgo(10))],
  }), { now: BASE_TIME });
  assert.equal(reopened.action, "none");
  assert.deepEqual(reopened.labelsToRemove, [LABELS.waitingForAuthor.name]);
});

test("draft PRs use the longer 14d nudge and 14d close windows", () => {
  const day10 = evaluatePullRequest(makePR({
    isDraft: true,
    createdAt: daysAgo(10),
    headCommit: { pushedDate: daysAgo(10) },
    labels: [LABELS.needsReview.name],
  }), { now: BASE_TIME });
  assert.equal(day10.action, "none");
  assert.deepEqual(day10.labelsToRemove, [LABELS.needsReview.name]);

  const day14 = evaluatePullRequest(makePR({
    isDraft: true,
    createdAt: daysAgo(14),
    headCommit: { pushedDate: daysAgo(14) },
  }), { now: BASE_TIME });
  assert.equal(day14.action, "nudge-author");
  assert.equal(day14.isDraft, true);
  assert.equal(day14.closeInDays, 14);

  const draftNudge10d = formatAuthorNudgeComment({
    authorLogin: "alice",
    headSha: "abc1234",
    isDraft: true,
    blockers: ["draft"],
    daysIdle: 14,
    closeInDays: 14,
    now: BASE_TIME - 10 * DAY_MS,
  });
  const day24 = evaluatePullRequest(makePR({
    isDraft: true,
    createdAt: daysAgo(24),
    headCommit: { pushedDate: daysAgo(24) },
    labels: [LABELS.waitingForAuthor.name],
    comments: [botComment(draftNudge10d, daysAgo(10))],
  }), { now: BASE_TIME });
  assert.equal(day24.action, "wait");

  const draftNudge14d = formatAuthorNudgeComment({
    authorLogin: "alice",
    headSha: "abc1234",
    isDraft: true,
    blockers: ["draft"],
    daysIdle: 14,
    closeInDays: 14,
    now: BASE_TIME - 14 * DAY_MS,
  });
  const day28 = evaluatePullRequest(makePR({
    isDraft: true,
    createdAt: daysAgo(28),
    headCommit: { pushedDate: daysAgo(28) },
    labels: [LABELS.waitingForAuthor.name],
    comments: [botComment(draftNudge14d, daysAgo(14))],
  }), { now: BASE_TIME });
  assert.equal(day28.action, "close-author");
  assert.equal(day28.isDraft, true);
});

test("review threads, CHANGES_REQUESTED, and DISMISSED reviews classify ownership accurately", () => {
  const waitingAuthor = evaluatePullRequest(makePR({
    createdAt: daysAgo(9),
    headCommit: { pushedDate: daysAgo(9) },
    reviews: [
      { author: { __typename: "User", login: "Seb-GRAF" }, authorAssociation: "OWNER", state: "CHANGES_REQUESTED", submittedAt: daysAgo(8) },
    ],
    reviewThreads: [
      { isResolved: false, comments: [{ author: { __typename: "User", login: "Seb-GRAF" }, authorAssociation: "OWNER", createdAt: daysAgo(8) }] },
    ],
  }), { now: BASE_TIME });
  assert.equal(waitingAuthor.action, "nudge-author");
  assert.deepEqual(waitingAuthor.blockers, [
    { kind: "changes-requested" },
    { kind: "unresolved-threads", count: 1 },
  ]);

  // Dismissing an earlier CHANGES_REQUESTED clears that blocker.
  const dismissed = evaluatePullRequest(makePR({
    createdAt: daysAgo(10),
    headCommit: { pushedDate: daysAgo(10) },
    reviews: [
      { author: { __typename: "User", login: "Seb-GRAF" }, authorAssociation: "OWNER", state: "CHANGES_REQUESTED", submittedAt: daysAgo(8) },
      { author: { __typename: "User", login: "Seb-GRAF" }, authorAssociation: "OWNER", state: "DISMISSED", submittedAt: daysAgo(5) },
    ],
  }), { now: BASE_TIME });
  assert.equal(dismissed.court, "maintainer");
  assert.equal(dismissed.action, "remind-maintainers");

  // Unordered review thread comments still pick the newest reply by createdAt.
  const waitingMaintainer = evaluatePullRequest(makePR({
    createdAt: daysAgo(10),
    headCommit: { pushedDate: daysAgo(5) },
    requestedReviewers: [],
    labels: [LABELS.waitingForAuthor.name],
    reviews: [
      { author: { __typename: "User", login: "Seb-GRAF" }, authorAssociation: "OWNER", state: "CHANGES_REQUESTED", submittedAt: daysAgo(8) },
    ],
    reviewThreads: [
      {
        isResolved: false,
        comments: [
          { author: { __typename: "User", login: "alice" }, authorAssociation: "FIRST_TIME_CONTRIBUTOR", createdAt: daysAgo(5) },
          { author: { __typename: "User", login: "Seb-GRAF" }, authorAssociation: "OWNER", createdAt: daysAgo(8) },
        ],
      },
    ],
  }), { now: BASE_TIME, fallbackReviewers: ["Seb-GRAF"] });
  assert.equal(waitingMaintainer.action, "remind-maintainers");
  assert.equal(waitingMaintainer.court, "maintainer");
  assert.deepEqual(waitingMaintainer.maintainerReasons, ["re-review", "thread-reply"]);
  assert.deepEqual(waitingMaintainer.reviewersToPing, ["Seb-GRAF"]);
  assert.deepEqual(waitingMaintainer.labelsToAdd, [LABELS.needsReview.name]);
  assert.deepEqual(waitingMaintainer.labelsToRemove, [LABELS.waitingForAuthor.name]);
});

test("PRs waiting on maintainers remind once after 4 days (including workflow approval and visual-ok) and never close", () => {
  const day3 = evaluatePullRequest(makePR({
    createdAt: daysAgo(3),
    headCommit: { pushedDate: daysAgo(3) },
    awaitingWorkflowApproval: true,
    labels: [LABELS.needsReview.name],
  }), { now: BASE_TIME });
  assert.equal(day3.action, "none");
  assert.deepEqual(day3.labelsToRemove, [LABELS.needsReview.name]);

  const day4 = evaluatePullRequest(makePR({
    createdAt: daysAgo(4),
    headCommit: { pushedDate: daysAgo(4) },
    awaitingWorkflowApproval: true,
    statusContexts: [
      { __typename: "StatusContext", context: "Visual review", state: "PENDING", description: "1 screen changed: a maintainer adds visual-ok after looking.", createdAt: daysAgo(4) },
    ],
    requestedReviewers: ["M4n0x", "Seb-GRAF"],
  }), { now: BASE_TIME });
  assert.equal(day4.action, "remind-maintainers");
  assert.deepEqual(day4.maintainerReasons, ["workflow-approval", "visual-review"]);
  assert.deepEqual(day4.reviewersToPing, ["M4n0x", "Seb-GRAF"]);
  assert.deepEqual(day4.labelsToAdd, [LABELS.needsReview.name]);

  const reminderBody = formatMaintainerReminderComment({
    headSha: "abc1234",
    reviewersToPing: ["M4n0x", "Seb-GRAF"],
    maintainerReasons: ["review"],
    daysIdle: 4,
    now: BASE_TIME - 26 * DAY_MS,
  });
  const day30 = evaluatePullRequest(makePR({
    createdAt: daysAgo(30),
    headCommit: { pushedDate: daysAgo(30) },
    labels: [LABELS.needsReview.name],
    comments: [botComment(reminderBody, daysAgo(26))],
  }), { now: BASE_TIME });
  assert.equal(day30.action, "wait");
  assert.equal(day30.reason, "already-reminded-maintainers");
});

test("comment formatting sanitizes check names and embeds valid markers", () => {
  const nudge = formatAuthorNudgeComment({
    authorLogin: "alice",
    headSha: "abc1234",
    isDraft: false,
    blockers: [{ kind: "failing-checks", checks: ["Test `evil` @everyone -->"] }],
    daysIdle: 7,
    closeInDays: 7,
    now: BASE_TIME,
  });
  assert.match(nudge, /Hi @alice/);
  assert.ok(nudge.includes("`Test 'evil' @everyone -->`"));
  assert.ok(readFollowupMarker(botComment(nudge, new Date(BASE_TIME).toISOString()))?.kind === "author-nudge");

  const close = formatAuthorCloseComment({ headSha: "abc1234", isDraft: true, daysSinceNudge: 14, now: BASE_TIME });
  assert.match(close, /draft pull request/);
  assert.match(close, /14 days ago/);
  assert.equal(readFollowupMarker(botComment(close, new Date(BASE_TIME).toISOString()))?.kind, "author-close");

  const reminder = formatMaintainerReminderComment({
    headSha: "abc1234",
    reviewersToPing: ["Seb-GRAF", "M4n0x"],
    maintainerReasons: ["workflow-approval", "visual-review"],
    daysIdle: 4,
    now: BASE_TIME,
  });
  assert.match(reminder, /@Seb-GRAF @M4n0x/);
  assert.match(reminder, /visual-ok/);
  assert.equal(readFollowupMarker(botComment(reminder, new Date(BASE_TIME).toISOString()))?.kind, "maintainer-reminder");
});

function makeGraphQLNode(overrides = {}) {
  return {
    number: 1,
    state: "OPEN",
    title: "Community PR",
    isDraft: false,
    createdAt: daysAgo(5),
    mergeable: "MERGEABLE",
    authorAssociation: "FIRST_TIME_CONTRIBUTOR",
    author: { __typename: "User", login: "bob" },
    headRefOid: "sha-1",
    headRefName: "fix/ready",
    headRepository: { nameWithOwner: "bob/StableBar" },
    labels: { nodes: [] },
    reviewRequests: { nodes: [{ requestedReviewer: { login: "Seb-GRAF" } }] },
    commits: { nodes: [{ commit: { oid: "sha-1", pushedDate: daysAgo(5), statusCheckRollup: { contexts: { nodes: [] } } } }] },
    timelineItems: { nodes: [] },
    reviews: { nodes: [] },
    reviewThreads: { nodes: [] },
    comments: { nodes: [] },
    ...overrides,
  };
}

test("runSweep handles dry-run, live close ordering, thread pagination, recheck abort, and per-PR error isolation", async () => {
  const ops = [];
  const oldNudge = (login, headSha) => formatAuthorNudgeComment({
    authorLogin: login,
    headSha,
    isDraft: false,
    blockers: [{ kind: "merge-conflicts" }],
    daysIdle: 7,
    closeInDays: 7,
    now: BASE_TIME - 7 * DAY_MS,
  });

  const pr1 = makeGraphQLNode({
    number: 1,
    authorAssociation: "COLLABORATOR",
    author: { __typename: "User", login: "M4n0x" },
    mergeable: "CONFLICTING",
    createdAt: daysAgo(20),
    commits: { nodes: [{ commit: { oid: "sha-team", pushedDate: daysAgo(20), statusCheckRollup: { contexts: { nodes: [] } } } }] },
  });

  // Paginated review thread: page 1 ends with maintainer, page 2 has author reply -> maintainer's court.
  const pr2 = makeGraphQLNode({
    number: 2,
    headRefOid: "sha-ready",
    createdAt: daysAgo(8),
    commits: { nodes: [{ commit: { oid: "sha-ready", pushedDate: daysAgo(8), statusCheckRollup: { contexts: { nodes: [] } } } }] },
    reviewThreads: {
      nodes: [{
        id: "thread-2",
        isResolved: false,
        comments: {
          pageInfo: { hasNextPage: true, endCursor: "c1" },
          nodes: [{ author: { __typename: "User", login: "Seb-GRAF" }, authorAssociation: "OWNER", createdAt: daysAgo(8) }],
        },
      }],
    },
  });

  // Eligible to close and stays eligible on recheck -> closes BEFORE posting comment.
  const pr3 = makeGraphQLNode({
    number: 3,
    author: { __typename: "User", login: "carol" },
    headRefOid: "sha-close",
    headRefName: "fix/close",
    headRepository: { nameWithOwner: "carol/StableBar" },
    mergeable: "CONFLICTING",
    createdAt: daysAgo(15),
    labels: { nodes: [{ name: LABELS.waitingForAuthor.name }] },
    commits: { nodes: [{ commit: { oid: "sha-close", pushedDate: daysAgo(15), statusCheckRollup: { contexts: { nodes: [] } } } }] },
    comments: { nodes: [botComment(oldNudge("carol", "sha-close"), daysAgo(7))] },
  });

  // Eligible to close in bulk snapshot, but maintainer adds keep-open before write -> close aborted.
  const pr4 = makeGraphQLNode({
    number: 4,
    author: { __typename: "User", login: "dave" },
    headRefOid: "sha-race",
    headRefName: "fix/race",
    headRepository: { nameWithOwner: "dave/StableBar" },
    mergeable: "CONFLICTING",
    createdAt: daysAgo(15),
    labels: { nodes: [{ name: LABELS.waitingForAuthor.name }] },
    commits: { nodes: [{ commit: { oid: "sha-race", pushedDate: daysAgo(15), statusCheckRollup: { contexts: { nodes: [] } } } }] },
    comments: { nodes: [botComment(oldNudge("dave", "sha-race"), daysAgo(7))] },
  });
  const pr4Fresh = { ...pr4, labels: { nodes: [{ name: LABELS.waitingForAuthor.name }, { name: LABELS.keepOpen }] } };

  // Fails on label write, but PR #6 still runs afterwards.
  const pr5 = makeGraphQLNode({
    number: 5,
    author: { __typename: "User", login: "erin" },
    headRefOid: "sha-err",
    createdAt: daysAgo(6),
    commits: { nodes: [{ commit: { oid: "sha-err", pushedDate: daysAgo(6), statusCheckRollup: { contexts: { nodes: [] } } } }] },
  });
  const pr6 = makeGraphQLNode({
    number: 6,
    author: { __typename: "User", login: "frank" },
    headRefOid: "sha-after",
    createdAt: daysAgo(6),
    commits: { nodes: [{ commit: { oid: "sha-after", pushedDate: daysAgo(6), statusCheckRollup: { contexts: { nodes: [] } } } }] },
  });

  const nodes = [pr1, pr2, pr3, pr4, pr5, pr6];
  const singleNodes = new Map([[3, pr3], [4, pr4Fresh]]);

  const makeGitHub = () => ({
    graphql: async (query, vars) => {
      if (query.includes("pullRequests(states: OPEN")) {
        return { repository: { pullRequests: { pageInfo: { hasNextPage: false, endCursor: null }, nodes } } };
      }
      if (query.includes("pullRequest(number:")) {
        return { repository: { pullRequest: singleNodes.get(vars.number) ?? null } };
      }
      if (query.includes("PullRequestReviewThread")) {
        return {
          node: {
            comments: {
              pageInfo: { hasNextPage: false, endCursor: null },
              nodes: [{ author: { __typename: "User", login: "bob" }, authorAssociation: "FIRST_TIME_CONTRIBUTOR", createdAt: daysAgo(5) }],
            },
          },
        };
      }
      throw new Error(`Unexpected query: ${query}`);
    },
    rest: {
      actions: {
        listWorkflowRunsForRepo: async ({ head_sha }) => ({
          data: {
            workflow_runs: head_sha === "sha-ready"
              ? [{ event: "pull_request", head_branch: "fix/ready", head_repository: { full_name: "bob/StableBar" } }]
              : [],
          },
        }),
      },
      issues: {
        createLabel: async (args) => { ops.push(["createLabel", args.name]); },
        addLabels: async (args) => {
          if (args.issue_number === 5) throw new Error("Simulated label failure");
          ops.push(["addLabels", args.issue_number, args.labels]);
        },
        removeLabel: async (args) => { ops.push(["removeLabel", args.issue_number, args.name]); },
        createComment: async (args) => { ops.push(["comment", args.issue_number, args.body]); },
      },
      pulls: {
        update: async (args) => { ops.push(["close", args.pull_number, args.state]); },
      },
    },
  });

  const context = { repo: { owner: "stablebox", repo: "StableBar" } };
  const warnings = [];
  const core = { info: () => {}, warning: (msg) => warnings.push(msg) };

  const dryResults = await runSweep({
    github: makeGitHub(),
    context,
    core,
    dryRun: true,
    now: BASE_TIME,
    fallbackReviewers: ["Seb-GRAF"],
  });
  assert.deepEqual(
    dryResults.map((r) => [r.number, r.action]),
    [[1, "skip"], [2, "remind-maintainers"], [3, "close-author"], [4, "close-author"], [5, "remind-maintainers"], [6, "remind-maintainers"]],
  );
  assert.equal(ops.length, 0);

  const liveResults = await runSweep({
    github: makeGitHub(),
    context,
    core,
    dryRun: false,
    now: BASE_TIME,
    fallbackReviewers: ["Seb-GRAF"],
  });
  assert.deepEqual(
    liveResults.map((r) => [r.number, r.action]),
    [[1, "skip"], [2, "remind-maintainers"], [3, "close-author"], [4, "skip"], [5, "error"], [6, "remind-maintainers"]],
  );
  assert.equal(warnings.length, 1);

  // Verify PR #3 closed BEFORE posting the closure notice, and PR #4 was never closed or commented on.
  const pr3Ops = ops.filter((op) => op[1] === 3).map((op) => op[0]);
  assert.deepEqual(pr3Ops, ["close", "comment"]);
  assert.equal(ops.some((op) => op[1] === 4), false);
  assert.equal(ops.some((op) => op[0] === "comment" && op[1] === 6), true);
});

test("clearWaitingLabel removes waiting-for-author on community PR activity", async () => {
  const removed = [];
  const github = {
    rest: {
      issues: {
        removeLabel: async (args) => { removed.push(args); },
      },
    },
  };
  const core = { info: () => {} };

  const cleared = await clearWaitingLabel({
    github,
    core,
    context: {
      repo: { owner: "stablebox", repo: "StableBar" },
      payload: {
        action: "synchronize",
        pull_request: {
          number: 42,
          user: { type: "User", login: "alice" },
          author_association: "FIRST_TIME_CONTRIBUTOR",
          labels: [{ name: LABELS.waitingForAuthor.name }],
        },
      },
    },
  });
  assert.equal(cleared, true);
  assert.deepEqual(removed, [{ owner: "stablebox", repo: "StableBar", issue_number: 42, name: LABELS.waitingForAuthor.name }]);

  const skipped = await clearWaitingLabel({
    github,
    core,
    context: {
      repo: { owner: "stablebox", repo: "StableBar" },
      payload: {
        action: "synchronize",
        pull_request: {
          number: 43,
          user: { type: "User", login: "Seb-GRAF" },
          author_association: "OWNER",
          labels: [{ name: LABELS.waitingForAuthor.name }],
        },
      },
    },
  });
  assert.equal(skipped, false);
});
