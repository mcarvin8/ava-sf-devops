#!/bin/bash
################################################################################
# Script: delete_stale_branches.sh
# Description: Deletes stale Git branches that have been merged into main or 
#              ContPar and haven't been updated in a specified time period.
#              Branches merged to main (1+ month old) and ContPar (1+ month old)
#              are deleted, plus any branches 3+ months old.
# Usage: Called from scheduled CI/CD pipeline
# Note: Protected branches cannot be deleted via this script
# Environment Variables Required:
#   - MAINTAINER_PAT_NAME, MAINTAINER_PAT_VALUE
################################################################################
before_date='1 month ago'
filter='git branch --merged origin/main -r'
git fetch -q
echo Deleting all branches merged into main branch last updated over $before_date
for k in $(${filter} | grep --invert-match origin/main | sed /\*/d); do 
    if [ "$(git log --before="$before_date" $k^..$k )" ]; then
        branch=$(echo $k | sed 's/origin\///')
        echo "Attemping to delete $branch"
        git push "https://${MAINTAINER_PAT_NAME}:${MAINTAINER_PAT_VALUE}@${CI_SERVER_HOST}/${CI_PROJECT_PATH}.git" --delete $branch
        # minor delay needed to prevent connection abort errors
        sleep 5
    fi
done
git fetch --prune -q
cpFilter='git branch --merged origin/ContPar -r'
echo Deleting all branches merged into ContPar branch last updated over $before_date
for k in $(${cpFilter} | grep --invert-match origin/ContPar | sed /\*/d); do 
    if [ "$(git log --before="$before_date" $k^..$k )" ]; then
        branch=$(echo $k | sed 's/origin\///')
        echo "Attemping to delete $branch"
        git push "https://${MAINTAINER_PAT_NAME}:${MAINTAINER_PAT_VALUE}@${CI_SERVER_HOST}/${CI_PROJECT_PATH}.git" --delete $branch
        # minor delay needed to prevent connection abort errors
        sleep 5
    fi
done
git fetch --prune -q
staleFilter='git branch -r'
stale_before_date='3 months ago'
echo Deleting all stale branches last updated over $stale_before_date
for k in $(${staleFilter} | grep --invert-match origin/main | sed /\*/d); do 
    if [ "$(git log --before="$stale_before_date" $k^..$k )" ]; then
        branch=$(echo $k | sed 's/origin\///')
        echo "Attemping to delete $branch"
        git push "https://${MAINTAINER_PAT_NAME}:${MAINTAINER_PAT_VALUE}@${CI_SERVER_HOST}/${CI_PROJECT_PATH}.git" --delete $branch
        # minor delay needed to prevent connection abort errors
        sleep 5
    fi
done
