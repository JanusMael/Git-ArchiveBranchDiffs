using System.ComponentModel;
using Microsoft.Extensions.AI;
using ModelContextProtocol.Server;

namespace GitArchiveMcp.Prompts;

[McpServerPromptType]
public static class ArchivePrompts
{
    [McpServerPrompt(Name = "review-changeset"),
     Description("Review all changes between two git refs — creates an archive and produces a structured code review")]
    public static IEnumerable<ChatMessage> ReviewChangeset(
        [Description("Base ref (e.g. 'main', 'v1.0.0')")] string leftRef,
        [Description("Feature ref (e.g. 'feature/auth', 'HEAD')")] string rightRef)
    {
        return
        [
            new(ChatRole.User,
                $"""
                I need a thorough code review of all changes between `{leftRef}` and `{rightRef}`.

                Steps:
                1. Call `git_archive_diffs` with leftRef="{leftRef}" and rightRef="{rightRef}"
                2. Call `git_archive_read` on the returned archivePath to get the full changeset
                3. Analyze the changes and produce a structured review

                Format your review as:

                ## Summary
                One paragraph overview of the changeset — what it accomplishes and its scope.

                ## Files Changed (by area)
                Group files by directory/module and briefly describe the changes in each area.

                ## Notable Changes
                Highlight the most significant or complex changes that deserve attention.

                ## Potential Issues
                Flag any concerns: bugs, security issues, performance problems, missing error handling,
                breaking changes, or code that doesn't match surrounding patterns.

                ## Test Coverage
                Note which changes have corresponding test updates and which do not.
                """)
        ];
    }

    [McpServerPrompt(Name = "resume-branch"),
     Description("Get up to speed on a branch — summarizes all committed work and in-progress changes")]
    public static IEnumerable<ChatMessage> ResumeBranch(
        [Description("Base branch to compare against (e.g. 'main')")] string baseBranch,
        [Description("Branch to resume work on (e.g. 'feature/auth', or 'HEAD' for current)")] string featureBranch = "HEAD")
    {
        return
        [
            new(ChatRole.User,
                $"""
                I'm resuming work on a branch and need to quickly understand what has been done.

                Steps:
                1. Call `git_archive_list` to check if an archive already exists for these refs
                2. If not, call `git_archive_diffs` with leftRef="{baseBranch}" and rightRef="{featureBranch}"
                3. Call `git_archive_read` on the archive to get the full picture
                4. Also call `git_archive_diffs` with leftRef="{baseBranch}" and mode="workingTree"
                   to capture any uncommitted work in progress
                5. If the workingTree archive has files, call `git_archive_read` on it too

                Produce a summary covering:

                ## Branch Overview
                What this branch appears to be doing, based on commit messages and changed files.

                ## Work Completed
                List the key changes already committed, organized by area/module.

                ## Commit History
                Summarize the progression of work from the HISTORY.md — how did the work evolve?

                ## In-Progress Changes
                If there are uncommitted changes, describe what appears to be work-in-progress.

                ## Key Files
                List the most important files that were modified, with a one-line description of each change.

                ## Suggested Next Steps
                Based on the pattern of changes, suggest what might logically come next.
                """)
        ];
    }

    [McpServerPrompt(Name = "compare-releases"),
     Description("Compare two release tags and produce a release-notes-style summary")]
    public static IEnumerable<ChatMessage> CompareReleases(
        [Description("Earlier release tag (e.g. 'v1.0.0')")] string fromTag,
        [Description("Later release tag (e.g. 'v2.0.0')")] string toTag)
    {
        return
        [
            new(ChatRole.User,
                $"""
                I need a release notes summary of all changes between `{fromTag}` and `{toTag}`.

                Steps:
                1. Call `git_archive_diffs` with leftRef="{fromTag}" and rightRef="{toTag}"
                2. Call `git_archive_read` on the returned archivePath
                3. Analyze the changeset and produce release notes

                Format the output as:

                ## Release Notes: {fromTag} → {toTag}

                ### Highlights
                The 3-5 most important changes, each with a brief description.

                ### New Features
                Features that were added (new files, new capabilities).

                ### Improvements
                Enhancements to existing functionality.

                ### Bug Fixes
                Issues that were resolved (look for fix/bug-related commit messages).

                ### Breaking Changes
                Any changes that could break existing usage (API changes, removed files,
                renamed exports, changed defaults).

                ### Contributors
                List contributors from the HISTORY.md churn summary.

                ### Files Changed
                Total count and a grouped summary by directory.
                """)
        ];
    }

    [McpServerPrompt(Name = "review-uncommitted"),
     Description("Review uncommitted working tree changes before committing — catches issues early")]
    public static IEnumerable<ChatMessage> ReviewUncommitted(
        [Description("Base branch to compare against (e.g. 'main')")] string baseBranch = "HEAD")
    {
        return
        [
            new(ChatRole.User,
                $"""
                Review my uncommitted changes before I commit them.

                Steps:
                1. Call `git_archive_diffs` with leftRef="{baseBranch}" and mode="workingTree"
                2. Call `git_archive_read` on the returned archivePath
                3. Analyze the changes for issues

                Focus your review on:

                ## Changes Summary
                What files are modified, added, or deleted.

                ## Issues Found
                Look specifically for:
                - Debug/temporary code left in (console.log, print statements, TODO/FIXME/HACK)
                - Commented-out code that should be removed
                - Hardcoded values that should be configurable
                - Missing error handling at boundaries
                - Security concerns (credentials, injection risks)
                - Files that look accidentally included (build artifacts, personal config)

                ## Suggestions
                Improvements to make before committing.

                ## Commit Message Draft
                Suggest a concise commit message based on the actual changes.
                """)
        ];
    }

    [McpServerPrompt(Name = "triage-changeset"),
     Description("Efficiently triage a large changeset — summary first, then targeted drill-down, then annotate findings")]
    public static IEnumerable<ChatMessage> TriageChangeset(
        [Description("Base ref (e.g. 'main')")] string leftRef,
        [Description("Feature ref (e.g. 'HEAD', 'feature/auth')")] string rightRef)
    {
        return
        [
            new(ChatRole.User,
                $"""
                Triage the changeset between `{leftRef}` and `{rightRef}`. Do NOT read the whole
                archive at once — use the zoom-in workflow so we stay focused on what matters.

                Steps:
                1. Call `git_archive_diffs` with leftRef="{leftRef}" and rightRef="{rightRef}"
                2. Call `git_archive_summary` on the returned archivePath to understand scope
                   (file count, lines added/removed, top directories, added/deleted/modified split)
                3. Based on the summary, identify 2-4 directories that carry the bulk of the change
                4. Call `git_archive_search` for risk patterns: `TODO|FIXME|HACK|XXX`, then
                   `console\.log|Console\.WriteLine|printf|dbg!` for leftover debug output, then
                   any domain-specific patterns that matter for this codebase
                5. For each high-impact file identified in steps 3-4, call `git_archive_diff_file`
                   to examine both sides and the diff hunk in detail
                6. Call `git_archive_annotate` to record findings: set `status=reviewed`,
                   `issues=<count>`, and `notes=<one-line summary>` so the state persists
                   across the session

                Produce a prioritized review:

                ## Scope
                Numbers from the summary: files, lines, top directories, binary count.

                ## High-Priority Findings
                The most impactful issues — ordered by severity. For each, cite the file:line
                and explain why it matters.

                ## Medium-Priority Findings
                Concerns worth mentioning but not blocking.

                ## Clean Areas
                Directories or files that look well-done — acknowledge them briefly.

                ## Suggested Next Actions
                Concrete follow-ups the author should take.
                """)
        ];
    }

    [McpServerPrompt(Name = "incremental-review"),
     Description("Incremental review — compare a new archive to a previously reviewed one and focus only on what changed")]
    public static IEnumerable<ChatMessage> IncrementalReview(
        [Description("Base ref (e.g. 'main')")] string leftRef,
        [Description("Feature ref (e.g. 'HEAD', 'feature/auth')")] string rightRef)
    {
        return
        [
            new(ChatRole.User,
                $"""
                Perform an incremental review of `{leftRef}` vs `{rightRef}`. I have already
                reviewed an earlier archive of this branch — focus only on what has changed
                since then.

                Steps:
                1. Call `git_archive_list` to find the previous archive for these refs.
                   Look for one annotated with `status=reviewed` via `git_archive_annotate`.
                2. Call `git_archive_diffs` with leftRef="{leftRef}" and rightRef="{rightRef}"
                   to create the current snapshot.
                3. Call `git_archive_compare` with the older archive and the new one.
                4. For each file in the `addedFiles` and `changedFiles` lists, call
                   `git_archive_diff_file` on the NEW archive to examine it.
                5. For each file in `removedFiles`, briefly note that it is no longer part
                   of the changeset (reverted or the branch moved).
                6. Call `git_archive_annotate` on the new archive with `status=reviewed`,
                   `previous=<old archive path>`, and `notes=<delta summary>`.

                Produce a focused delta review:

                ## Since Last Review
                One paragraph: what the developer did between the two archives.

                ## New / Changed Files
                For each, a short per-file assessment — is it an improvement, a regression,
                or neutral? Reference earlier findings if you have them.

                ## Removed From Changeset
                Files that were in the previous archive but not this one.

                ## Residual Concerns
                Issues from the previous review that are still present.

                ## Sign-off Readiness
                Is this branch ready to merge, or does it need another pass?
                """)
        ];
    }

    [McpServerPrompt(Name = "review-staged"),
     Description("Review staged changes — focused pre-commit review of exactly what will be committed")]
    public static IEnumerable<ChatMessage> ReviewStaged(
        [Description("Base ref to compare against (e.g. 'HEAD')")] string baseBranch = "HEAD")
    {
        return
        [
            new(ChatRole.User,
                $"""
                Review exactly what I have staged for the next commit.

                Steps:
                1. Call `git_archive_diffs` with leftRef="{baseBranch}" and mode="staged"
                2. Call `git_archive_read` on the returned archivePath
                3. Analyze only the staged changes

                Produce a focused review:

                ## Staged Changes
                List every file with its change type (added/modified/deleted/renamed).

                ## Review
                For each changed file, note anything concerning — this is the last check
                before the commit is created.

                ## Completeness
                Do the staged changes look like a complete, coherent unit of work?
                Are there files that were probably meant to be included but aren't staged?

                ## Commit Message
                Suggest a commit message that accurately describes these specific staged changes.
                Follow conventional commit style if the repository uses it.
                """)
        ];
    }
}
