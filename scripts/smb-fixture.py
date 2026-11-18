#!/usr/bin/env python3
"""Read-only loopback SMB2 test fixture. Requires impacket; no NAS credentials used."""
import argparse
import logging
from pathlib import Path
from impacket import smbserver, smb3structs
from impacket.nt_errors import STATUS_SUCCESS
from impacket.ntlm import compute_lmhash, compute_nthash

parser = argparse.ArgumentParser()
parser.add_argument('--media', required=True)
parser.add_argument('--work-dir', required=True)
args = parser.parse_args()
root = Path(args.work_dir).resolve()
(root / '剧集').mkdir(parents=True, exist_ok=True)
(root / '剧集' / 'Fixture.S01E01.mp4').write_bytes(Path(args.media).read_bytes())
# Test-only fixed credentials; bind exclusively to loopback.
logging.disable(logging.CRITICAL)
server = smbserver.SimpleSMBServer(listenAddress='127.0.0.1', listenPort=14455)
server.addShare('Movies', str(root), readOnly='yes')
server.setSMB2Support(True)
server.addCredential('luma-test', 0, compute_lmhash('fixture-only'), compute_nthash('fixture-only'))
# Preserve the session ID in LOGOFF responses. Impacket 0.13 clears it before
# serializing the response, which makes strict SMB clients time out on shutdown.
def logoff(conn_id, smb_server, packet):
    return [smb3structs.SMB2Logoff_Response()], None, STATUS_SUCCESS
server.getServer().hookSmb2Command(smb3structs.SMB2_LOGOFF, logoff)
print('SMB fixture: smb://127.0.0.1:14455, luma-test / fixture-only', flush=True)
server.start()
