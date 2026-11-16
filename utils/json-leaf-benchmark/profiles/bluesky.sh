# Profile for the public JSONBench Bluesky data (see bluesky/download.sh and bluesky/convert.sh).
# Skip the subtrees commit.record.{subject,embed,reply,facets}, including array elements below them.
# The regex is anchored, so the partial-match setting of the `JSON` type does not change the result.
RE='^commit[.]record[.](subject|embed|reply|facets)([.].*|[[].*)?$'
# Tables C and D use the same regex, so all four indexes hold the same values.
JT_C="JSON(SKIP REGEXP '$RE')"
JT_D="JSON(max_dynamic_paths = 0, SKIP REGEXP '$RE')"
# role=token. `commerce` is rare, `like` is a collection name in about half of the documents.
# The third token is the CID of one post. It occurs only under `subject`, so it is skipped.
TOKENS=(rare=commerce common=like skipped=bafyreie7b4ebxlpl4l6xqc6rmrypywqfodgm5o3htmxwwgcjrd36bc7fpq)

extra_function_cases() { :; }
