# TMDB

Movie and TV data and posters are supplied by The Movie Database.
This product uses the TMDB API but is not endorsed or certified by TMDB.

API documentation: https://developer.themoviedb.org/docs/getting-started
Attribution requirements: https://developer.themoviedb.org/docs/faq

The unmodified TMDB logo by Travis Bell is sourced from the Wikimedia Commons copy of the official TMDB blue_square_2 logo:
https://commons.wikimedia.org/wiki/File:Tmdb.new.logo.svg
Original: https://www.themoviedb.org/assets/2/v4/logos/v2/blue_square_2-d537fb228cf3ded904ef09b136fe3fec72548ebc1fea3fbbd1ad9e36364db38b.svg
License as recorded by Commons: CC BY-SA 4.0 (https://creativecommons.org/licenses/by-sa/4.0/).
No changes made to the logo.


# libmpv / FFmpeg and codec dependencies

libmpv 0.42.0 is obtained from the official Homebrew core formula. The default mpv build is GPL-2.0-or-later; FFmpeg and other dependencies have their own licenses. The C bridge uses libmpv's ISC-licensed client API. Original license files and formula build receipts are copied from installed formulae into the app's Resources/ThirdParty directory. An exact list of bundled library filenames and source installation paths is in Resources/ThirdParty-libraries.json.

Sources and build instructions:
- https://github.com/mpv-player/mpv/tree/v0.42.0
- https://mpv.io/manual/stable/
- https://ffmpeg.org/download.html
- https://github.com/Homebrew/homebrew-core/tree/HEAD/Formula

Before external redistribution, assemble corresponding source and build material for the exact bundled GPL/LGPL dependency versions, and retain the required notices. This artifact is a local development build, not a public release.
