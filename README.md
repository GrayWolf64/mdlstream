# MDLStream

This repo is a mirrored one, from a secret Gitea host to public GitHub.

# Usage

`mdlstream.SendRequest(mdl_path: string, callback: function)`

Sends a sync request on a specified file(size <= 8 MB), whose extension must be one of `vvd`, `phy` and `mdl` and content is *header-correct*.
After server tells client that sync(transmission and file build) successful, client will execute the given callback.

Detailed workings please turn to the source file, easy to read.

If you are a client, your first request must be fulfilled in order that your subsequent request be handled, and your subsequent request must
be fulfilled so that your more subsequent request be handled.

# Attention

1. `mdlstream` currently doesn't check if the specified file already exists on server
2. You may not use this lib(`mdlstream.lua`) if you *include this file and remove its boilerplate*; You may not use snippets from this lib
if you don't include their original authors
3. You may ask for permission if you would like to use this lib in non-free projects(addons)
4. No warranty
