#!/bin/bash
# Invents a small, entirely fictional working directory.
#
# Nothing here comes from the machine running the capture: no real repository, no real
# host name, no real address, no credential. It exists so that `ls`, `git status` and a
# file open in vim have something plausible and safe to show.
set -e
cd /home/deploy
[ -f .seeded ] && exit 0

export GIT_AUTHOR_NAME="Ada Okonkwo"
export GIT_AUTHOR_EMAIL="ada@example.invalid"
export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME"
export GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"
export GIT_AUTHOR_DATE="2026-08-14T09:12:00+0000"
export GIT_COMMITTER_DATE="$GIT_AUTHOR_DATE"
git config --global init.defaultBranch main
git config --global user.name "$GIT_AUTHOR_NAME"
git config --global user.email "$GIT_AUTHOR_EMAIL"
git config --global --add safe.directory '*'
# `git log` through a pager leaves the alternate screen holding the output, which is not
# where a screenshot — or a scrollback search — can see it.
git config --global core.pager cat

mkdir -p services/api/src services/api/config services/web logs

cat > services/api/README.md <<'DOC'
# api

A small HTTP service. Sample data for a screenshot; nothing here is deployed anywhere.

    make run      # start on :8080
    make test     # unit tests
DOC

cat > services/api/src/server.go <<'DOC'
package main

import (
	"log"
	"net/http"
	"time"
)

// Server is the HTTP front end that the
// worker pool reports its health through.
type Server struct {
	Addr    string
	Timeout time.Duration
}

func (s *Server) routes() *http.ServeMux {
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", ok)
	mux.HandleFunc("/readyz", ok)
	return mux
}

func ok(w http.ResponseWriter, _ *http.Request) {
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte("ok"))
}

func main() {
	s := &Server{
		Addr:    ":8080",
		Timeout: 5 * time.Second,
	}
	log.Printf("listening on %s", s.Addr)
	err := http.ListenAndServe(s.Addr, s.routes())
	if err != nil {
		log.Fatal(err)
	}
}
DOC

cat > services/api/src/queue.go <<'DOC'
package main

import "sync"

// Queue is a bounded FIFO used by the worker pool.
type Queue struct {
	mu    sync.Mutex
	items []string
	limit int
}

func NewQueue(limit int) *Queue { return &Queue{limit: limit} }

func (q *Queue) Push(item string) bool {
	q.mu.Lock()
	defer q.mu.Unlock()
	if len(q.items) >= q.limit {
		return false
	}
	q.items = append(q.items, item)
	return true
}
DOC

cat > services/api/config/api.yaml <<'DOC'
listen: ":8080"
workers: 4
timeouts:
  read: 5s
  write: 10s
DOC

cat > services/api/Makefile <<'DOC'
run:
	go run ./src

test:
	go test ./...
DOC

cat > services/web/index.html <<'DOC'
<!doctype html>
<meta charset="utf-8">
<title>web</title>
<h1>placeholder</h1>
DOC

cat > notes.md <<'DOC'
# notes

- rotate the staging certificate before the end of the month
- the worker pool still needs a bounded retry
- write up the queue limit decision
DOC

printf 'ok\n' > logs/health.log

cd services/api
git init -q .
git add -A
git commit -q -m "api: initial service, health endpoint"
GIT_AUTHOR_DATE="2026-08-21T16:40:00+0000" GIT_COMMITTER_DATE="2026-08-21T16:40:00+0000" \
  git commit -q --allow-empty -m "api: bound the worker queue"
GIT_AUTHOR_DATE="2026-08-29T11:05:00+0000" GIT_COMMITTER_DATE="2026-08-29T11:05:00+0000" \
  git commit -q --allow-empty -m "config: shorter read timeout"
# A working tree with something in it: `git status` is worth showing only when it has
# something to say.
printf '\n// TODO: retry with backoff\n' >> src/queue.go
cat > src/metrics.go <<'DOC'
package main

// Metrics counts what the queue does, for the /healthz payload.
type Metrics struct {
	Pushed  int
	Dropped int
}
DOC
cd /home/deploy
touch .seeded
