# WIP: MDLStream

This repo is a mirrored one, from a secret Gitea host to public GitHub.

# Usage

`mdlstream.SendRequest(mdl_path: string, callback: function)`

Sends a sync request on a specified file(size <= 8 MB), whose extension must be one of `vvd`, `phy`, `vtx`, `ani` and `mdl` and content is *header-correct*.
After server tells client that sync(transmission and file build) successful, client will execute the given callback.

Detailed workings please turn to the source file, easy to read.

If you are a client, your requests are all enqueued serverside, each request action can run only if the previous one is already ran(finished). You can submit `mdt` in console to open `MDLStream Debugging Tool`, a currently simple interface to avoid switching from gmod and editor constantly when debugging.

In singleplayer, api is not enabled.

# Future Plans

Make the most of a single and slow `netchan`.