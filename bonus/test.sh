TOKEN="$(cat ./token)"
kubectl exec -n gitlab -it -c toolbox "$(kubectl get pods -n gitlab | grep toolbox | cut -d ' ' -f1)" -- gitlab-rails runner "$(cat ./generateToken.rb)" | tr -d '\r' >token

it init --initial-branch=main
git remote add origin https://root:$TOKEN@gitlab.ta.mere/root/lcamerly-p3-app.git
git add IoT-p3-lcamerly/.*
git commit -m "Initial commit"
git push --set-upstream origin main