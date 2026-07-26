#!/bin/bash

# Remove untracked build and cache folders from Git repository
git rm -r --cached .gradle build 2>/dev/null || true
