#!/bin/bash
if sudo -n /usr/local/bin/mem-reduct-clean 2>/dev/null; then
    echo '{"success": true, "method": "sudo"}'
elif pkexec /usr/local/bin/mem-reduct-clean 2>/dev/null; then
    echo '{"success": true, "method": "pkexec"}'
else
    echo '{"success": false, "error": "Permission denied"}'
fi
