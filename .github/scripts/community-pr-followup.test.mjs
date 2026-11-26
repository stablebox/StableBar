import { test } from "node:test";
import assert from "node:assert/strict";
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

test("defaultCodeowners reads fallback reviewers from the repository CODEOWNERS", () => {
  assert.deepEqual(defaultCodeowners(), ["Seb-GRAF"]);
  assert.deepEqual(defaultCodeowners("# comment\n* @alice @bob @org/team\n/docs/ @carol\n"), ["alice", "bob"]);
});

test("readFollowupMarker only trusts bot comments", () => {
  const body = formatAuthorNudgeComment({
    authorLogin: "alice",
    headSha: "abc1234",
    isDraft: false,
    blockers: [{ kind: "merge-conflicts" }],
    daysIdle: 7,
    closeInDays: 7,
    now: BASE_TIME,
  });

  const parsed = readFollowupMarker(botComment(body, new Date(BASE_TIME).toISOString()));
  assert.equal(parsed?.kind, "author-nudge");
  assert.equal(parsed?.headSha, "abc1234");
  assert.equal(parsed?.draft, false);
  assert.equal(parsed?.at, BASE_TIME);

  // Human users cannot spoof the marker.
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

  // Day 6: too early to nudge.
  const day6 = evaluatePullRequest(makePR({ createdAt: daysAgo(6), headCommit: { pushedDate: daysAgo(6) }, statusContexts: failing }), { now: BASE_TIME });
  assert.equal(day6.action, "none");
  assert.equal(day6.court, "author");

  // Day 7: nudge author, add waiting-for-author, remove stale needs-review if present.
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

  // Day 13 (6 days after nudge): still waiting in grace period.
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

  // Day 14 (7 days after nudge): auto-close.
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

  // Author replied after the nudge -> clears waiting-for-author and resets clock.
  const nudgeBody = formatAuthorNudgeComment({
    authorLogin: "alice",
    headSha: "abc1234",
    isDraft: false,
    blockers: [{ kind: "failing-checks", checks: ["Test"] }],
    daysIdle: 7,
    closeInDays: 7,
    now: daysAgo(8) ? BASE_TIME - 8 * DAY_MS : BASE_TIME,
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

  // Reopened PR does not immediately re-close.
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
  // Day 10: still too early for draft nudge (even though ready PRs nudge at 7d).
  const day10 = evaluatePullRequest(makePR({
    isDraft: true,
    createdAt: daysAgo(10),
    headCommit: { pushedDate: daysAgo(10) },
    labels: [LABELS.needsReview.name],
  }), { now: BASE_TIME });
  assert.equal(day10.action, "none");
  assert.deepEqual(day10.labelsToRemove, [LABELS.needsReview.name]);

  // Day 14: nudge draft.
  const day14 = evaluatePullRequest(makePR({
    isDraft: true,
    createdAt: daysAgo(14),
    headCommit: { pushedDate: daysAgo(14) },
  }), { now: BASE_TIME });
  assert.equal(day14.action, "nudge-author");
  assert.equal(day14.isDraft, true);
  assert.equal(day14.closeInDays, 14);

  // Day 24 (10 days after draft nudge): still waiting.
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

  // Day 28 (14 days after draft nudge): close draft.
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

test("review threads and CHANGES_REQUESTED distinguish waiting on author vs waiting on maintainer", () => {
  // Maintainer requested changes 8 days ago; author has not pushed or replied -> author's court.
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

  // Author pushed a fix and replied in the thread 5 days ago -> maintainer's court (re-review + thread-reply).
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
          { author: { __typename: "User", login: "Seb-GRAF" }, authorAssociation: "OWNER", createdAt: daysAgo(8) },
          { author: { __typename: "User", login: "alice" }, authorAssociation: "FIRST_TIME_CONTRIBUTOR", createdAt: daysAgo(5) },
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
  // Day 3: too early.
  const day3 = evaluatePullRequest(makePR({
    createdAt: daysAgo(3),
    headCommit: { pushedDate: daysAgo(3) },
    awaitingWorkflowApproval: true,
    labels: [LABELS.needsReview.name],
  }), { now: BASE_TIME });
  assert.equal(day3.action, "none");
  assert.deepEqual(day3.labelsToRemove, [LABELS.needsReview.name]);

  // Day 4: remind maintainers with specific reasons.
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

  // Day 30 after maintainer reminder: still waits, NEVER closes or double-pings.
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

test("runSweep executes dry-run and live actions against GitHub API mocks", async () => {
  const calls = { labelsCreated: [], labelsAdded: [], labelsRemoved: [], comments: [], closed: [] };
  const makeGitHub = (nodes, actionRequiredShas = new Set()) => ({
    graphql: async () => ({ repository: { pullRequests: { pageInfo: { hasNextPage: false, endCursor: null }, nodes } } }),
    rest: {
      actions: {
        listWorkflowRunsForRepo: async ({ head_sha }) => ({
          data: {
            workflow_runs: actionRequiredShas.has(head_sha)
              ? [{ event: "pull_request", head_branch: "fix/ready", head_repository: { full_name: "bob/StableBar" } }]
              : [],
          },
        }),
      },
      issues: {
        createLabel: async (args) => { calls.labelsCreated.push(args.name); },
        addLabels: async (args) => { calls.labelsAdded.push(args); },
        removeLabel: async (args) => { calls.labelsRemoved.push(args); },
        createComment: async (args) => { calls.comments.push(args); },
      },
      pulls: {
        update: async (args) => { calls.closed.push(args); },
      },
    },
  });

  const oldNudge = formatAuthorNudgeComment({
    authorLogin: "carol",
    headSha: "sha-close",
    isDraft: false,
    blockers: [{ kind: "merge-conflicts" }],
    daysIdle: 7,
    closeInDays: 7,
    now: BASE_TIME - 7 * DAY_MS,
  });

  const nodes = [
    {
      number: 1,
      title: "Team PR",
      isDraft: false,
      createdAt: daysAgo(20),
      mergeable: "CONFLICTING",
      authorAssociation: "COLLABORATOR",
      author: { __typename: "User", login: "M4n0x" },
      headRefOid: "sha-team",
      headRefName: "ci/x",
      headRepository: { nameWithOwner: "stablebox/StableBar" },
      labels: { nodes: [] },
      reviewRequests: { nodes: [] },
      commits: { nodes: [{ commit: { oid: "sha-team", pushedDate: daysAgo(20), statusCheckRollup: { contexts: { nodes: [] } } } }] },
      timelineItems: { nodes: [] },
      reviews: { nodes: [] },
      reviewThreads: { nodes: [] },
      comments: { nodes: [] },
    },
    {
      number: 2,
      title: "Community PR waiting on CI approval",
      isDraft: false,
      createdAt: daysAgo(5),
      mergeable: "MERGEABLE",
      authorAssociation: "FIRST_TIME_CONTRIBUTOR",
      author: { __typename: "User", login: "bob" },
      headRefOid: "sha-ready",
      headRefName: "fix/ready",
      headRepository: { nameWithOwner: "bob/StableBar" },
      labels: { nodes: [] },
      reviewRequests: { nodes: [{ requestedReviewer: { login: "Seb-GRAF" } }] },
      commits: { nodes: [{ commit: { oid: "sha-ready", pushedDate: daysAgo(5), statusCheckRollup: { contexts: { nodes: [] } } } }] },
      timelineItems: { nodes: [] },
      reviews: { nodes: [] },
      reviewThreads: { nodes: [] },
      comments: { nodes: [] },
    },
    {
      number: 3,
      title: "Community PR abandoned after nudge",
      isDraft: false,
      createdAt: daysAgo(15),
      mergeable: "CONFLICTING",
      authorAssociation: "CONTRIBUTOR",
      author: { __typename: "User", login: "carol" },
      headRefOid: "sha-close",
      headRefName: "fix/close",
      headRepository: { nameWithOwner: "carol/StableBar" },
      labels: { nodes: [{ name: LABELS.waitingForAuthor.name }] },
      reviewRequests: { nodes: [] },
      commits: { nodes: [{ commit: { oid: "sha-close", pushedDate: daysAgo(15), statusCheckRollup: { contexts: { nodes: [] } } } }] },
      timelineItems: { nodes: [] },
      reviews: { nodes: [] },
      reviewThreads: { nodes: [] },
      comments: { nodes: [botComment(oldNudge, daysAgo(7))] },
    },
  ];

  const context = { repo: { owner: "stablebox", repo: "StableBar" } };
  const logs = [];
  const core = { info: (msg) => logs.push(msg) };

  // Dry run mutates nothing.
  const dryResults = await runSweep({
    github: makeGitHub(nodes, new Set(["sha-ready"])),
    context,
    core,
    dryRun: true,
    now: BASE_TIME,
    fallbackReviewers: ["Seb-GRAF"],
  });
  assert.deepEqual(dryResults.map((r) => [r.number, r.action]), [[1, "skip"], [2, "remind-maintainers"], [3, "close-author"]]);
  assert.equal(calls.comments.length, 0);
  assert.equal(calls.closed.length, 0);
  assert.equal(calls.labelsAdded.length, 0);

  // Live run labels, comments, and closes appropriately.
  await runSweep({
    github: makeGitHub(nodes, new Set(["sha-ready"])),
    context,
    core,
    dryRun: false,
    now: BASE_TIME,
    fallbackReviewers: ["Seb-GRAF"],
  });
  assert.deepEqual(calls.labelsCreated, [LABELS.needsReview.name]);
  assert.deepEqual(calls.labelsAdded, [{ owner: "stablebox", repo: "StableBar", issue_number: 2, labels: [LABELS.needsReview.name] }]);
  assert.equal(calls.comments.length, 2);
  assert.equal(calls.comments[0].issue_number, 2);
  assert.match(calls.comments[0].body, /waiting for approval/);
  assert.equal(calls.comments[1].issue_number, 3);
  assert.deepEqual(calls.closed, [{ owner: "stablebox", repo: "StableBar", pull_number: 3, state: "closed" }]);
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

  // Skips team PRs.
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
