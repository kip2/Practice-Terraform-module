#!/bin/bash
# set -euxo pipefail
# exec > /tmp/user_data.log 2>&1

# cd /home/ec2-user
cat > index.html <<EOF
<h1>Hello, World</h1>
<p>DB address: ${db_address}</p>
<p>DB port: ${db_port}</p>
EOF

nohup python3 -m http.server ${server_port} &
