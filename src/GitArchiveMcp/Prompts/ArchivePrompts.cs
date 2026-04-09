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
