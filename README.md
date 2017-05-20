# MatroskaServer
A simple HTTP streaming server for Matroska

* 起動すると 7000 番ポートで待機します。
* ffmpeg から matroska フォーマットの動画を HTTP Push できます。
* Push に使った URL を GET すると動画がストリームされます。
* `/stats` で利用状況が見られます。
