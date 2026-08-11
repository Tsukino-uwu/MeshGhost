// Module path is local-only ("meshghost") rather than a github.com/<owner>/... path
// because no repo destination has been chosen yet. Update this — and every import path
// under cmd/ and internal/ — the day this project gets a real remote, in the same commit.
module meshghost

go 1.22
