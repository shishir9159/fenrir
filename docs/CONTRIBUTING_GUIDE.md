## Reporting problems
- Check the FAQ.
- Search existing issues (including closed!)
- Update fenrir to the latest version to see if your problem persists.
- If a specific configuration or plugin is necessary to recreate the problem, use the minimal template in .
- Bisect your config: disable plugins incrementally, to narrow down the cause of the issue.
- Bisect fenrir's source code to find the cause of a regression, if you can.
- When reporting a crash, include a stacktrace.
- Use ASAN/UBSAN to get detailed errors for segfaults and undefined behavior.

## Developer guidelines
- Read :help dev-quickstart to see how to run tests and start hacking on the codebase.
- Read :help dev and :help dev-doc if you are working on fenrir core.
- Read :help dev-ui if you are developing a UI.

## Guidelines
- Don't ask to be assigned to an issue, just send a (reasonably complete) PR and mark it as Draft until it is ready for review.
- Your PR must include test coverage.
- Avoid cosmetic changes to unrelated files in the same commit.
- Use a feature branch instead of the master branch.
- Use a rebase workflow. After addressing review comments, it's fine to force-push.

## AI-assisted work
Using AI for contributions is acceptable, given the following:

-  YOU review the output before sending a non-Draft PR. Do NOT request review until YOU have checked the AI generated PR and verify the following:
REMOVE verbosity and blathering from documentation, comments, PR description, commit message, etc. All resources, including names, should be CONCISE and CLEAR. They should contain USEFUL information and nothing more.
- REMOVE and DEDUPLICATE redundant code, tests, explanations, etc. Explicitness and clarity are GOOD but verbosity, over-explanation, and redundancy is BAD.
