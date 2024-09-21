# WIP: MDLStream

This repo is a mirrored one, from a secret Gitea host to public GitHub.

# Usage

`mdlstream.SendRequest(mdl_path: string, callback: function)`

Sends a sync request on a specified file(size <= 8 MB), whose extension must be one of `vvd`, `phy`, `vtx`, `ani` and `mdl` and content is *header-correct*.
After server tells client that sync(transmission and file build) successful, client will execute the given callback.

Detailed workings please turn to the source file, easy to read.

If you are a client, your requests are all enqueued clientside, each request action can run only if the previous one is already ran(finished).

In singleplayer, api is not enabled.

# Attention

`mdlstream` currently doesn't check if the specified file already exists on server.
