// Follow-up logic for open community pull requests. .github/workflows/community-pr-followup.yml
// checks out the default branch's copy of this module so fork pull requests never run their own.
import { readFileSync } from "node:fs";

export const DAY_MS = 24 * 60 * 60 * 1000;

export const POLICY = {
  maintainerReminderDays: 4,
  authorNudgeDays: 7,
  authorCloseAfterNudgeDays: 7,
  draftNudgeDays: 14,
  draftCloseAfterNudgeDays: 14,
};

export const LABELS = {
  waitingForAuthor: {
    name: "waiting-for-author",
    color: "d4c5f9",
    description: "Waiting for changes or a reply from the pull request author",
  },
  needsReview: {
    name: "needs-review",
    color: "fbca04",
    description: "Community pull request waiting for a maintainer",
  },
  keepOpen: "keep-open",
};

const TEAM_ASSOCIATIONS = new Set(["OWNER", "MEMBER", "COLLABORATOR"]);
const DECISIVE_REVIEW_STATES = new Set(["APPROVED", "CHANGES_REQUESTED", "DISMISSED"]);
const FAILING_CHECK_CONCLUSIONS = new Set(["FAILURE", "TIMED_OUT", "STARTUP_FAILURE"]);
const FAILING_STATUS_STATES = new Set(["FAILURE", "ERROR"]);
const MARKER_PREFIX = "<!-- stablebar-community-pr-followup ";
const MARKER_PATTERN = /<!-- stablebar-community-pr-followup (\{[^\r\n]*\}) -->\s*$/;

const plural = (count, word) => `${count} ${word}${count === 1 ? "" : "s"}`;

/** Inline code span that neutralizes markdown, HTML and mentions in untrusted names. */
function code(text, limit = 120) {
  const cleaned = Array.from(String(text ?? "").replace(/\s+/g, " ").trim());
  const cut = cleaned.length <= limit ? cleaned.join("") : `${cleaned.slice(0, limit - 1).join("")}…`;
  return `\`${cut.replaceAll("`", "'") || " "}\``;
}

/** Safe JSON embedded inside an HTML comment so no value can terminate the comment early. */
function encodeMarker(data) {
  const json = JSON.stringify(data).replace(/[<>&]/g, (ch) => `\\u${ch.charCodeAt(0).toString(16).padStart(4, "0")}`);
  return `${MARKER_PREFIX}${json} -->`;
}

/** Valid GitHub login (without `@`) formatted as a mention. */
function mention(login) {
  return typeof login === "string" && /^[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?$/.test(login) ? `@${login}` : null;
}

function parseTime(value) {
  if (!value) return null;
  const ms = Date.parse(value);
  return Number.isFinite(ms) ? ms : null;
}

function maxTime(...values) {
  let latest = null;
  for (const value of values) {
    const ms = typeof value === "number" ? value : parseTime(value);
    if (ms !== null && (latest === null || ms > latest)) latest = ms;
  }
  return latest;
}

function minTime(...values) {
  let earliest = null;
  for (const value of values) {
    const ms = typeof value === "number" ? value : parseTime(value);
    if (ms !== null && (earliest === null || ms < earliest)) earliest = ms;
  }
  return earliest;
}

/** Whether a GraphQL or REST user object represents a bot account. */
export function isBotUser(user) {
  if (!user) return true;
  if (user.__typename === "Bot" || user.type === "Bot") return true;
  const login = String(user.login ?? "");
  return login === "" || /\[bot\]$/i.test(login);
}

/** Community contributors are non-bot accounts outside OWNER, MEMBER and COLLABORATOR. */
export function isCommunityAuthor(author, authorAssociation) {
  if (isBotUser(author)) return false;
  return !TEAM_ASSOCIATIONS.has(authorAssociation);
}

export function isTeamMember(author, authorAssociation) {
  if (isBotUser(author)) return false;
  return TEAM_ASSOCIATIONS.has(authorAssociation);
}

/** Reads default fallback reviewers from the `*` rule in `.github/CODEOWNERS`. */
export function defaultCodeowners(codeownersText) {
  const text = codeownersText ?? readFileSync(new URL("../CODEOWNERS", import.meta.url), "utf8");
  const owners = [];
  for (const rawLine of text.split(/\r?\n/)) {
    const line = rawLine.replace(/#.*$/, "").trim();
    if (!line) continue;
    const parts = line.split(/\s+/);
    if (parts[0] === "*") {
      for (const token of parts.slice(1)) {
        if (token.startsWith("@") && !token.includes("/")) {
          const login = token.slice(1);
          if (mention(login) && !owners.includes(login)) owners.push(login);
        }
      }
    }
  }
  return owners;
}

/** Parses our own follow-up marker from a bot comment, preferring GitHub's publication timestamp. */
export function readFollowupMarker(comment) {
  const actor = comment?.author ?? comment?.user;
  if (!actor || !isBotUser(actor)) return null;
  const match = String(comment.body ?? "").match(MARKER_PATTERN);
  if (!match) return null;
  try {
    const data = JSON.parse(match[1]);
    if (!data || typeof data !== "object" || typeof data.kind !== "string") return null;
    const at = parseTime(comment.createdAt ?? comment.created_at) ?? parseTime(data.at);
    return { ...data, at };
  } catch {
    return null;
  }
}

/**
 * Summarizes the head commit's check runs and commit statuses, keeping the newest entry per name.
 * Distinguishes Visual review's `visual-ok` wait (maintainer) from base-changed / failed checks (author).
 */
export function analyzeChecks(contexts = []) {
  const latestRuns = new Map();
  const latestStatuses = new Map();

  for (const item of contexts) {
    if (!item) continue;
    if (item.__typename === "CheckRun" || "conclusion" in item) {
      const name = item.name;
      if (!name) continue;
      const ts = maxTime(item.completedAt, item.startedAt) ?? 0;
      const prev = latestRuns.get(name);
      if (!prev || ts >= prev.ts) latestRuns.set(name, { item, ts });
    } else if (item.__typename === "StatusContext" || "context" in item) {
      const name = item.context;
      if (!name) continue;
      const ts = parseTime(item.createdAt) ?? 0;
      const prev = latestStatuses.get(name);
      if (!prev || ts >= prev.ts) latestStatuses.set(name, { item, ts });
    }
  }

  const failingChecks = [];
  let visualReviewPending = false;
  let baseChanged = false;

  for (const [name, { item }] of latestRuns) {
    if (item.status === "COMPLETED" && FAILING_CHECK_CONCLUSIONS.has(item.conclusion)) {
      failingChecks.push(name);
    }
  }

  for (const [name, { item }] of latestStatuses) {
    const state = String(item.state ?? "").toUpperCase();
    const description = String(item.description ?? "");
    if (name === "Visual review") {
      if (state === "PENDING" && description.includes("visual-ok")) {
        visualReviewPending = true;
      } else if (state === "PENDING" && description.includes("The base changed")) {
        baseChanged = true;
      } else if (FAILING_STATUS_STATES.has(state)) {
        failingChecks.push(name);
      }
      continue;
    }
    if (FAILING_STATUS_STATES.has(state)) {
      failingChecks.push(name);
    }
  }

  failingChecks.sort();
  return { failingChecks, visualReviewPending, baseChanged };
}

/**
 * Classifies an open community PR's current state, whose court the ball is in, the relevant
 * blockers/reasons, and the timestamps that govern follow-up and closing windows.
 */
export function evaluatePullRequest(pr, { now, policy = POLICY, fallbackReviewers = [] } = {}) {
  const labels = (pr.labels ?? []).map((label) => (typeof label === "string" ? label : label.name));
  const hasLabel = (name) => labels.includes(name);

  if (!isCommunityAuthor(pr.author, pr.authorAssociation)) {
    return { action: "skip", reason: "not-community", labelsToAdd: [], labelsToRemove: [] };
  }

  if (hasLabel(LABELS.keepOpen)) {
    return { action: "skip", reason: "keep-open", labelsToAdd: [], labelsToRemove: [] };
  }

  const authorLogin = pr.author.login.toLowerCase();
  const isAuthor = (user) => !isBotUser(user) && user?.login?.toLowerCase() === authorLogin;

  // GitHub no longer populates Commit.pushedDate, so also use the earliest check-suite or check-run
  // timestamp on the head commit (immutable across reruns) to detect fast-forward pushes of older commits.
  const firstHeadCheckAt = minTime(
    ...(pr.headCommit?.checkSuiteCreatedAts ?? []),
    ...(pr.statusContexts ?? []).map((item) => (item?.__typename === "CheckRun" || "conclusion" in (item ?? {}) ? item.startedAt : item?.createdAt)),
  );
  const headCommitAt = maxTime(pr.headCommit?.pushedDate, pr.headCommit?.committedDate, pr.headCommit?.authoredDate, firstHeadCheckAt);
  const timelineAt = maxTime(...(pr.timelineDates ?? []));

  let lastAuthorCommentAt = null;
  let lastHumanCommentAt = null;
  let lastAuthorNudge = null;
  let lastMaintainerReminder = null;

  for (const comment of pr.comments ?? []) {
    const marker = readFollowupMarker(comment);
    if (marker) {
      if (marker.kind === "author-nudge" && (!lastAuthorNudge || (marker.at ?? 0) >= (lastAuthorNudge.at ?? 0))) {
        lastAuthorNudge = marker;
      } else if (
        marker.kind === "maintainer-reminder"
        && (!lastMaintainerReminder || (marker.at ?? 0) >= (lastMaintainerReminder.at ?? 0))
      ) {
        lastMaintainerReminder = marker;
      }
      continue;
    }
    if (isBotUser(comment.author)) continue;
    const at = parseTime(comment.createdAt);
    lastHumanCommentAt = maxTime(lastHumanCommentAt, at);
    if (isAuthor(comment.author)) lastAuthorCommentAt = maxTime(lastAuthorCommentAt, at);
  }

  // Track latest decisive human maintainer review per reviewer, including DISMISSED so dismissed
  // change requests no longer block.
  const latestMaintainerReview = new Map();
  let lastHumanReviewAt = null;
  let lastAuthorReviewAt = null;

  for (const review of pr.reviews ?? []) {
    if (isBotUser(review.author)) continue;
    const at = parseTime(review.submittedAt);
    lastHumanReviewAt = maxTime(lastHumanReviewAt, at);
    if (isAuthor(review.author)) lastAuthorReviewAt = maxTime(lastAuthorReviewAt, at);
    if (isTeamMember(review.author, review.authorAssociation) && DECISIVE_REVIEW_STATES.has(review.state)) {
      const login = review.author.login;
      const prev = latestMaintainerReview.get(login);
      if (!prev || (at ?? 0) >= (prev.at ?? 0)) {
        latestMaintainerReview.set(login, { state: review.state, at, login });
      }
    }
  }

  // Pick each unresolved thread's newest reply by createdAt rather than array order.
  let unresolvedAuthorThreads = 0;
  let unresolvedMaintainerThreads = 0;
  let lastAuthorThreadAt = null;
  let lastHumanThreadAt = null;

  for (const thread of pr.reviewThreads ?? []) {
    const threadComments = thread.comments ?? [];
    let latestComment = null;
    let latestCommentAt = null;
    for (const c of threadComments) {
      const at = parseTime(c.createdAt);
      if (latestComment === null || (at ?? -Infinity) >= (latestCommentAt ?? -Infinity)) {
        latestComment = c;
        latestCommentAt = at;
      }
      if (isBotUser(c.author)) continue;
      lastHumanThreadAt = maxTime(lastHumanThreadAt, at);
      if (isAuthor(c.author)) lastAuthorThreadAt = maxTime(lastAuthorThreadAt, at);
    }
    if (thread.isResolved || !latestComment) continue;
    if (isAuthor(latestComment.author)) {
      unresolvedMaintainerThreads += 1;
    } else {
      unresolvedAuthorThreads += 1;
    }
  }

  const createdAt = parseTime(pr.createdAt);
  const lastAuthorActivityAt = maxTime(createdAt, headCommitAt, timelineAt, lastAuthorCommentAt, lastAuthorReviewAt, lastAuthorThreadAt);
  const lastHumanActivityAt = maxTime(lastAuthorActivityAt, lastHumanCommentAt, lastHumanReviewAt, lastHumanThreadAt);

  if (pr.isDraft) {
    const labelsToRemove = hasLabel(LABELS.needsReview.name) ? [LABELS.needsReview.name] : [];
    const activeNudge = lastAuthorNudge
      && lastAuthorNudge.draft === true
      && lastAuthorNudge.headSha === pr.headRefOid
      && (lastAuthorNudge.at ?? 0) >= lastHumanActivityAt
      ? lastAuthorNudge
      : null;

    if (activeNudge) {
      const daysSinceNudge = (now - activeNudge.at) / DAY_MS;
      if (daysSinceNudge >= policy.draftCloseAfterNudgeDays) {
        return {
          action: "close-author",
          court: "author",
          isDraft: true,
          blockers: ["draft"],
          daysIdle: Math.floor((now - lastHumanActivityAt) / DAY_MS),
          daysSinceNudge: Math.floor(daysSinceNudge),
          labelsToAdd: [],
          labelsToRemove,
        };
      }
      return {
        action: "wait",
        reason: "already-nudged-draft",
        court: "author",
        isDraft: true,
        blockers: ["draft"],
        labelsToAdd: hasLabel(LABELS.waitingForAuthor.name) ? [] : [LABELS.waitingForAuthor.name],
        labelsToRemove,
      };
    }

    if (hasLabel(LABELS.waitingForAuthor.name)) labelsToRemove.push(LABELS.waitingForAuthor.name);
    const daysIdle = (now - lastHumanActivityAt) / DAY_MS;
    if (daysIdle >= policy.draftNudgeDays) {
      return {
        action: "nudge-author",
        court: "author",
        isDraft: true,
        blockers: ["draft"],
        daysIdle: Math.floor(daysIdle),
        closeInDays: policy.draftCloseAfterNudgeDays,
        labelsToAdd: hasLabel(LABELS.waitingForAuthor.name) ? [] : [LABELS.waitingForAuthor.name],
        labelsToRemove: labelsToRemove.filter((name) => name !== LABELS.waitingForAuthor.name),
      };
    }
    return {
      action: "none",
      court: "author",
      isDraft: true,
      blockers: ["draft"],
      labelsToAdd: [],
      labelsToRemove,
    };
  }

  const { failingChecks, visualReviewPending, baseChanged } = analyzeChecks(pr.statusContexts ?? []);
  const changesRequestedReviews = [...latestMaintainerReview.values()].filter((r) => r.state === "CHANGES_REQUESTED");
  const latestChangesRequestedAt = maxTime(...changesRequestedReviews.map((r) => r.at));
  const authorUpdatedAfterChangesRequested = latestChangesRequestedAt !== null
    && maxTime(headCommitAt, lastAuthorCommentAt, lastAuthorThreadAt) > latestChangesRequestedAt;
  const changesRequestedPendingAuthor = changesRequestedReviews.length > 0 && !authorUpdatedAfterChangesRequested;

  const authorBlockers = [];
  if (failingChecks.length > 0) authorBlockers.push({ kind: "failing-checks", checks: failingChecks });
  if (baseChanged) authorBlockers.push({ kind: "base-changed" });
  if (pr.mergeable === "CONFLICTING") authorBlockers.push({ kind: "merge-conflicts" });
  if (changesRequestedPendingAuthor) authorBlockers.push({ kind: "changes-requested" });
  if (unresolvedAuthorThreads > 0) authorBlockers.push({ kind: "unresolved-threads", count: unresolvedAuthorThreads });

  if (authorBlockers.length > 0) {
    const labelsToRemove = hasLabel(LABELS.needsReview.name) ? [LABELS.needsReview.name] : [];
    const activeNudge = lastAuthorNudge
      && lastAuthorNudge.draft === false
      && lastAuthorNudge.headSha === pr.headRefOid
      && (lastAuthorNudge.at ?? 0) >= lastHumanActivityAt
      ? lastAuthorNudge
      : null;

    if (activeNudge) {
      const daysSinceNudge = (now - activeNudge.at) / DAY_MS;
      if (daysSinceNudge >= policy.authorCloseAfterNudgeDays) {
        return {
          action: "close-author",
          court: "author",
          isDraft: false,
          blockers: authorBlockers,
          daysIdle: Math.floor((now - lastHumanActivityAt) / DAY_MS),
          daysSinceNudge: Math.floor(daysSinceNudge),
          labelsToAdd: [],
          labelsToRemove,
        };
      }
      return {
        action: "wait",
        reason: "already-nudged",
        court: "author",
        isDraft: false,
        blockers: authorBlockers,
        labelsToAdd: hasLabel(LABELS.waitingForAuthor.name) ? [] : [LABELS.waitingForAuthor.name],
        labelsToRemove,
      };
    }

    if (hasLabel(LABELS.waitingForAuthor.name)) labelsToRemove.push(LABELS.waitingForAuthor.name);
    const daysIdle = (now - lastHumanActivityAt) / DAY_MS;
    if (daysIdle >= policy.authorNudgeDays) {
      return {
        action: "nudge-author",
        court: "author",
        isDraft: false,
        blockers: authorBlockers,
        daysIdle: Math.floor(daysIdle),
        closeInDays: policy.authorCloseAfterNudgeDays,
        labelsToAdd: hasLabel(LABELS.waitingForAuthor.name) ? [] : [LABELS.waitingForAuthor.name],
        labelsToRemove: labelsToRemove.filter((name) => name !== LABELS.waitingForAuthor.name),
      };
    }

    return {
      action: "none",
      court: "author",
      isDraft: false,
      blockers: authorBlockers,
      labelsToAdd: [],
      labelsToRemove,
    };
  }

  const labelsToRemove = hasLabel(LABELS.waitingForAuthor.name) ? [LABELS.waitingForAuthor.name] : [];
  const maintainerReasons = [];
  if (pr.awaitingWorkflowApproval) maintainerReasons.push("workflow-approval");
  if (visualReviewPending) maintainerReasons.push("visual-review");
  if (changesRequestedReviews.length > 0 && authorUpdatedAfterChangesRequested) maintainerReasons.push("re-review");
  if (unresolvedMaintainerThreads > 0) maintainerReasons.push("thread-reply");
  if (maintainerReasons.length === 0) maintainerReasons.push("review");

  const reviewersToPing = selectReviewersToPing(pr, latestMaintainerReview, fallbackReviewers);
  const activeReminder = lastMaintainerReminder
    && (!lastMaintainerReminder.headSha || lastMaintainerReminder.headSha === pr.headRefOid)
    && (lastMaintainerReminder.at ?? 0) >= lastHumanActivityAt
    ? lastMaintainerReminder
    : null;

  if (activeReminder) {
    return {
      action: "wait",
      reason: "already-reminded-maintainers",
      court: "maintainer",
      isDraft: false,
      maintainerReasons,
      reviewersToPing,
      labelsToAdd: hasLabel(LABELS.needsReview.name) ? [] : [LABELS.needsReview.name],
      labelsToRemove,
    };
  }

  const daysIdle = (now - lastHumanActivityAt) / DAY_MS;
  if (daysIdle >= policy.maintainerReminderDays) {
    return {
      action: "remind-maintainers",
      court: "maintainer",
      isDraft: false,
      maintainerReasons,
      reviewersToPing,
      daysIdle: Math.floor(daysIdle),
      labelsToAdd: hasLabel(LABELS.needsReview.name) ? [] : [LABELS.needsReview.name],
      labelsToRemove,
    };
  }

  if (hasLabel(LABELS.needsReview.name)) labelsToRemove.push(LABELS.needsReview.name);

  return {
    action: "none",
    court: "maintainer",
    isDraft: false,
    maintainerReasons,
    reviewersToPing,
    labelsToAdd: [],
    labelsToRemove,
  };
}

function selectReviewersToPing(pr, latestMaintainerReview, fallbackReviewers) {
  const requested = (pr.requestedReviewers ?? []).filter((login) => mention(login));
  if (requested.length > 0) return [...new Set(requested)];
  const priorMaintainers = [...latestMaintainerReview.keys()].filter((login) => mention(login));
  if (priorMaintainers.length > 0) return [...new Set(priorMaintainers)];
  return [...new Set((fallbackReviewers ?? []).filter((login) => mention(login)))];
}

function formatBlockerBullet(blocker) {
  switch (blocker.kind) {
    case "failing-checks":
      return `- Failing ${blocker.checks.length === 1 ? "check" : "checks"}: ${blocker.checks.map((name) => code(name)).join(", ")}`;
    case "base-changed":
      return "- The base branch changed; push a commit so Visual review can compare against it";
    case "merge-conflicts":
      return "- Merge conflicts with the base branch";
    case "changes-requested":
      return "- Changes were requested in review";
    case "unresolved-threads":
      return `- ${plural(blocker.count, "unresolved review thread")}`;
    default:
      return null;
  }
}

function formatMaintainerReasonBullet(reason) {
  switch (reason) {
    case "workflow-approval":
      return "- First-time contributor workflow runs are waiting for approval to run";
    case "visual-review":
      return "- Changed screens are waiting for visual review (`visual-ok`)";
    case "re-review":
      return "- The author pushed an update or replied after requested changes";
    case "thread-reply":
      return "- The author replied in an unresolved review thread";
    case "review":
      return "- Ready for review";
    default:
      return null;
  }
}

export function formatAuthorNudgeComment({ authorLogin, headSha, isDraft, blockers, daysIdle, closeInDays, now }) {
  const authorRef = mention(authorLogin) ?? "there";
  const marker = encodeMarker({ kind: "author-nudge", headSha, draft: Boolean(isDraft), at: new Date(now).toISOString() });

  if (isDraft) {
    return [
      `Hi ${authorRef}, checking in on this draft pull request — it has been quiet for ${plural(daysIdle, "day")}.`,
      "",
      `If you're still working on it, push a commit, leave a comment, or mark it ready for review whenever you're ready. Without an update, this draft will close automatically in ${plural(closeInDays, "day")} (you can always reopen it later). Maintainers can add \`${LABELS.keepOpen}\` to pause follow-ups.`,
      "",
      marker,
    ].join("\n");
  }

  const bullets = blockers.map(formatBlockerBullet).filter(Boolean);
  return [
    `Hi ${authorRef}, checking in on this pull request — it has been quiet for ${plural(daysIdle, "day")} and is waiting on updates before it can move forward:`,
    "",
    ...bullets,
    "",
    `If you're still working on it, push an update or leave a comment whenever you're ready. Without an update, this pull request will close automatically in ${plural(closeInDays, "day")} (you can always reopen it later). Maintainers can add \`${LABELS.keepOpen}\` to pause follow-ups.`,
    "",
    marker,
  ].join("\n");
}

export function formatAuthorCloseComment({ headSha, isDraft, daysSinceNudge, now }) {
  const marker = encodeMarker({ kind: "author-close", headSha, draft: Boolean(isDraft), at: new Date(now).toISOString() });
  const kind = isDraft ? "draft pull request" : "pull request";
  return [
    `Closing this ${kind} for now since there hasn't been an update since the follow-up ${plural(daysSinceNudge, "day")} ago.`,
    "",
    "Thanks for the contribution — feel free to reopen it or open a fresh pull request whenever you have time to pick it back up.",
    "",
    marker,
  ].join("\n");
}

export function formatMaintainerReminderComment({ headSha, reviewersToPing, maintainerReasons, daysIdle, now }) {
  const marker = encodeMarker({ kind: "maintainer-reminder", headSha, at: new Date(now).toISOString() });
  const pings = reviewersToPing.map(mention).filter(Boolean);
  const greeting = pings.length > 0 ? `Friendly reminder for ${pings.join(" ")}:` : "Friendly reminder for maintainers:";
  const bullets = maintainerReasons.map(formatMaintainerReasonBullet).filter(Boolean);
  return [
    `${greeting} this community pull request has been waiting on a maintainer for ${plural(daysIdle, "day")}.`,
    "",
    ...bullets,
    "",
    marker,
  ].join("\n");
}

const PR_FIELDS = `
  number
  state
  title
  isDraft
  createdAt
  mergeable
  authorAssociation
  author { __typename login }
  headRefOid
  headRefName
  headRepository { nameWithOwner }
  labels(first: 50) { nodes { name } }
  reviewRequests(first: 20) {
    nodes {
      requestedReviewer {
        ... on User { login }
      }
    }
  }
  commits(last: 1) {
    nodes {
      commit {
        oid
        authoredDate
        committedDate
        pushedDate
        checkSuites(first: 10) {
          nodes { createdAt }
        }
        statusCheckRollup {
          contexts(first: 100) {
            nodes {
              __typename
              ... on CheckRun { name status conclusion startedAt completedAt }
              ... on StatusContext { context state description createdAt }
            }
          }
        }
      }
    }
  }
  timelineItems(last: 30, itemTypes: [READY_FOR_REVIEW_EVENT, CONVERT_TO_DRAFT_EVENT, REOPENED_EVENT, HEAD_REF_FORCE_PUSHED_EVENT]) {
    nodes {
      __typename
      ... on ReadyForReviewEvent { createdAt }
      ... on ConvertToDraftEvent { createdAt }
      ... on ReopenedEvent { createdAt }
      ... on HeadRefForcePushedEvent { createdAt }
    }
  }
  reviews(last: 50) {
    nodes {
      author { __typename login }
      authorAssociation
      state
      submittedAt
    }
  }
  reviewThreads(first: 100) {
    nodes {
      id
      isResolved
      comments(first: 20) {
        pageInfo { hasNextPage endCursor }
        nodes {
          author { __typename login }
          authorAssociation
          createdAt
        }
      }
    }
  }
  comments(last: 100) {
    nodes {
      author { __typename login }
      authorAssociation
      body
      createdAt
    }
  }
`;

const OPEN_PRS_QUERY = `
query($owner: String!, $repo: String!, $cursor: String) {
  repository(owner: $owner, name: $repo) {
    pullRequests(states: OPEN, first: 25, after: $cursor, orderBy: { field: CREATED_AT, direction: ASC }) {
      pageInfo { hasNextPage endCursor }
      nodes { ${PR_FIELDS} }
    }
  }
}`;

const SINGLE_PR_QUERY = `
query($owner: String!, $repo: String!, $number: Int!) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $number) { ${PR_FIELDS} }
  }
}`;

const THREAD_COMMENTS_QUERY = `
query($threadId: ID!, $cursor: String!) {
  node(id: $threadId) {
    ... on PullRequestReviewThread {
      comments(first: 100, after: $cursor) {
        pageInfo { hasNextPage endCursor }
        nodes {
          author { __typename login }
          authorAssociation
          createdAt
        }
      }
    }
  }
}`;

function normalizeGraphQLPullRequest(node) {
  const headCommit = node.commits?.nodes?.[0]?.commit ?? null;
  return {
    number: node.number,
    state: node.state ?? "OPEN",
    title: node.title,
    isDraft: node.isDraft,
    createdAt: node.createdAt,
    mergeable: node.mergeable,
    authorAssociation: node.authorAssociation,
    author: node.author,
    headRefOid: node.headRefOid,
    headRefName: node.headRefName,
    headRepository: node.headRepository?.nameWithOwner ?? null,
    labels: (node.labels?.nodes ?? []).map((l) => l.name),
    requestedReviewers: (node.reviewRequests?.nodes ?? []).map((r) => r.requestedReviewer?.login).filter(Boolean),
    headCommit: headCommit ? {
      oid: headCommit.oid,
      authoredDate: headCommit.authoredDate,
      committedDate: headCommit.committedDate,
      pushedDate: headCommit.pushedDate,
      checkSuiteCreatedAts: (headCommit.checkSuites?.nodes ?? []).map((suite) => suite?.createdAt).filter(Boolean),
    } : null,
    statusContexts: headCommit?.statusCheckRollup?.contexts?.nodes ?? [],
    timelineDates: (node.timelineItems?.nodes ?? []).map((item) => item?.createdAt).filter(Boolean),
    reviews: node.reviews?.nodes ?? [],
    reviewThreads: (node.reviewThreads?.nodes ?? []).map((thread) => ({
      id: thread.id ?? null,
      isResolved: thread.isResolved,
      comments: [...(thread.comments?.nodes ?? [])],
      commentsPageInfo: thread.comments?.pageInfo ?? { hasNextPage: false, endCursor: null },
    })),
    comments: node.comments?.nodes ?? [],
  };
}

/** Fetches remaining comments on any review thread that exceeded the initial page. */
async function hydrateThreadComments({ github, pr }) {
  for (const thread of pr.reviewThreads ?? []) {
    if (!thread.id || !thread.commentsPageInfo?.hasNextPage) continue;
    let cursor = thread.commentsPageInfo.endCursor;
    while (cursor) {
      const data = await github.graphql(THREAD_COMMENTS_QUERY, { threadId: thread.id, cursor });
      const page = data?.node?.comments;
      if (!page) break;
      thread.comments.push(...(page.nodes ?? []));
      cursor = page.pageInfo?.hasNextPage ? page.pageInfo.endCursor : null;
    }
    thread.commentsPageInfo = { hasNextPage: false, endCursor: null };
  }
}

async function hasActionRequiredWorkflowRuns({ github, owner, repo, pr }) {
  if (!pr.headRefOid) return false;
  const { data } = await github.rest.actions.listWorkflowRunsForRepo({
    owner,
    repo,
    head_sha: pr.headRefOid,
    status: "action_required",
    per_page: 20,
  });
  return (data.workflow_runs ?? []).some((run) => run.event === "pull_request"
    && (!pr.headRefName || run.head_branch === pr.headRefName)
    && (!pr.headRepository || !run.head_repository?.full_name || run.head_repository.full_name === pr.headRepository));
}

async function hydrateCommunityPullRequest({ github, owner, repo, pr }) {
  await hydrateThreadComments({ github, pr });
  if (!pr.isDraft && !pr.labels.includes(LABELS.keepOpen)) {
    pr.awaitingWorkflowApproval = await hasActionRequiredWorkflowRuns({ github, owner, repo, pr });
  }
}

async function fetchSinglePullRequest({ github, owner, repo, number }) {
  const data = await github.graphql(SINGLE_PR_QUERY, { owner, repo, number });
  const node = data?.repository?.pullRequest;
  if (!node) return null;
  const pr = normalizeGraphQLPullRequest(node);
  if (pr.state === "OPEN" && isCommunityAuthor(pr.author, pr.authorAssociation)) {
    await hydrateCommunityPullRequest({ github, owner, repo, pr });
  }
  return pr;
}

async function ensureLabel({ github, owner, repo, labelSpec, knownLabels }) {
  if (knownLabels.has(labelSpec.name)) return;
  try {
    await github.rest.issues.createLabel({
      owner,
      repo,
      name: labelSpec.name,
      color: labelSpec.color,
      description: labelSpec.description,
    });
  } catch (error) {
    if (error?.status !== 422) throw error;
  }
  knownLabels.add(labelSpec.name);
}

async function listOpenPullRequests({ github, owner, repo }) {
  const prs = [];
  let cursor = null;
  do {
    const data = await github.graphql(OPEN_PRS_QUERY, { owner, repo, cursor });
    const connection = data.repository.pullRequests;
    for (const node of connection.nodes) prs.push(normalizeGraphQLPullRequest(node));
    cursor = connection.pageInfo.hasNextPage ? connection.pageInfo.endCursor : null;
  } while (cursor);
  return prs;
}

async function applyLabelChanges({ github, owner, repo, number, labelsToAdd, labelsToRemove, labelSpecsByName, knownLabels }) {
  for (const labelName of labelsToAdd ?? []) {
    const spec = labelSpecsByName.get(labelName);
    if (spec) await ensureLabel({ github, owner, repo, labelSpec: spec, knownLabels });
  }
  if ((labelsToAdd ?? []).length > 0) {
    await github.rest.issues.addLabels({ owner, repo, issue_number: number, labels: labelsToAdd });
  }
  for (const labelName of labelsToRemove ?? []) {
    try {
      await github.rest.issues.removeLabel({ owner, repo, issue_number: number, name: labelName });
    } catch (error) {
      if (error?.status !== 404) throw error;
    }
  }
}

/**
 * Runs the daily follow-up sweep across open community pull requests (or a single PR if `pullRequestNumber` is set).
 * Catches and records per-PR errors so one failing PR does not block follow-ups on the rest.
 */
export async function runSweep({ github, context, core, dryRun = false, pullRequestNumber = null, now = Date.now(), fallbackReviewers = defaultCodeowners() }) {
  const { owner, repo } = context.repo;
  const allOpen = await listOpenPullRequests({ github, owner, repo });
  const targets = pullRequestNumber ? allOpen.filter((pr) => pr.number === Number(pullRequestNumber)) : allOpen;
  const labelSpecsByName = new Map([
    [LABELS.waitingForAuthor.name, LABELS.waitingForAuthor],
    [LABELS.needsReview.name, LABELS.needsReview],
  ]);
  const knownLabels = new Set();
  const results = [];

  for (const pr of targets) {
    if (!isCommunityAuthor(pr.author, pr.authorAssociation)) {
      results.push({ number: pr.number, action: "skip", reason: "not-community" });
      continue;
    }

    try {
      await hydrateCommunityPullRequest({ github, owner, repo, pr });
      let activePr = pr;
      let decision = evaluatePullRequest(activePr, { now, fallbackReviewers });

      const summary = `#${activePr.number} (${activePr.author.login}): ${decision.action}`
        + (decision.court ? ` [court=${decision.court}]` : "")
        + (decision.reason ? ` (${decision.reason})` : "");
      core.info(dryRun ? `[dry-run] ${summary}` : summary);

      if (dryRun) {
        results.push({ number: activePr.number, ...decision });
        continue;
      }

      // Re-verify live PR state right before nudging or closing so concurrent pushes, replies or
      // keep-open labels are never overridden by the earlier bulk snapshot.
      if (decision.action === "nudge-author" || decision.action === "close-author") {
        const expectedAction = decision.action;
        const fresh = await fetchSinglePullRequest({ github, owner, repo, number: activePr.number });
        const freshDecision = fresh && fresh.state === "OPEN"
          ? evaluatePullRequest(fresh, { now, fallbackReviewers })
          : null;
        if (!fresh || fresh.state !== "OPEN" || fresh.headRefOid !== activePr.headRefOid || freshDecision?.action !== expectedAction) {
          core.info(`#${activePr.number}: skipped ${expectedAction} because PR state changed before write.`);
          results.push({ number: activePr.number, action: "skip", reason: "state-changed" });
          continue;
        }
        activePr = fresh;
        decision = freshDecision;
      }

      await applyLabelChanges({
        github,
        owner,
        repo,
        number: activePr.number,
        labelsToAdd: decision.labelsToAdd,
        labelsToRemove: decision.labelsToRemove,
        labelSpecsByName,
        knownLabels,
      });

      if (decision.action === "nudge-author") {
        const body = formatAuthorNudgeComment({
          authorLogin: activePr.author.login,
          headSha: activePr.headRefOid,
          isDraft: activePr.isDraft,
          blockers: decision.blockers,
          daysIdle: decision.daysIdle,
          closeInDays: decision.closeInDays,
          now,
        });
        await github.rest.issues.createComment({ owner, repo, issue_number: activePr.number, body });
      } else if (decision.action === "close-author") {
        // Close before posting the closure notice so a failed close never leaves a misleading notice on an open PR.
        await github.rest.pulls.update({ owner, repo, pull_number: activePr.number, state: "closed" });
        const body = formatAuthorCloseComment({
          headSha: activePr.headRefOid,
          isDraft: activePr.isDraft,
          daysSinceNudge: decision.daysSinceNudge,
          now,
        });
        await github.rest.issues.createComment({ owner, repo, issue_number: activePr.number, body });
      } else if (decision.action === "remind-maintainers") {
        const body = formatMaintainerReminderComment({
          headSha: activePr.headRefOid,
          reviewersToPing: decision.reviewersToPing,
          maintainerReasons: decision.maintainerReasons,
          daysIdle: decision.daysIdle,
          now,
        });
        await github.rest.issues.createComment({ owner, repo, issue_number: activePr.number, body });
      }

      results.push({ number: activePr.number, ...decision });
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      (core.warning ?? core.info)(`#${pr.number}: follow-up failed: ${message}`);
      results.push({ number: pr.number, action: "error", error: message });
    }
  }

  return results;
}

/**
 * Clears `waiting-for-author` immediately when a community contributor pushes, reopens, or marks ready.
 */
export async function clearWaitingLabel({ github, context, core }) {
  const { owner, repo } = context.repo;
  const pr = context.payload.pull_request;
  if (!pr || !isCommunityAuthor(pr.user, pr.author_association)) return false;
  if (!(pr.labels ?? []).some((label) => label.name === LABELS.waitingForAuthor.name)) return false;
  try {
    await github.rest.issues.removeLabel({ owner, repo, issue_number: pr.number, name: LABELS.waitingForAuthor.name });
    core.info(`Removed ${LABELS.waitingForAuthor.name} from #${pr.number} after ${context.payload.action}.`);
    return true;
  } catch (error) {
    if (error?.status === 404) return false;
    throw error;
  }
}
