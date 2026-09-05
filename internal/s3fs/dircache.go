package s3fs

import (
	"strings"
	"sync"
	"time"

	"github.com/hanwen/go-fuse/v2/fuse"
)

// dirCache caches directory listings for a short TTL. Local mutations
// invalidate the affected directory immediately, so the TTL only governs how
// quickly writes made by *other* clients become visible.
type dirCache struct {
	mu  sync.RWMutex
	m   map[string]*dirCacheEntry
	ttl time.Duration
	// exclusive listings never expire: only this mount can change the bucket,
	// and every local mutation invalidates the directory it touched.
	exclusive bool
	maxSize   int
}

type dirCacheEntry struct {
	entries []fuse.DirEntry
	expires time.Time
}

func newDirCache(ttl time.Duration, exclusive bool) *dirCache {
	return &dirCache{
		m:         make(map[string]*dirCacheEntry),
		ttl:       ttl,
		exclusive: exclusive,
		maxSize:   20000,
	}
}

func (c *dirCache) get(p string) ([]fuse.DirEntry, bool) {
	c.mu.RLock()
	e, ok := c.m[p]
	c.mu.RUnlock()
	if !ok || (!c.exclusive && time.Now().After(e.expires)) {
		return nil, false
	}
	return e.entries, true
}

func (c *dirCache) put(p string, entries []fuse.DirEntry) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if len(c.m) > c.maxSize {
		c.trimLocked()
	}
	c.m[p] = &dirCacheEntry{entries: entries, expires: time.Now().Add(c.ttl)}
}

// trimLocked bounds the cache. Expired listings go first; if that is not enough
// (nothing expires in exclusive mode) arbitrary listings are dropped, which
// only costs a re-listing.
func (c *dirCache) trimLocked() {
	now := time.Now()
	if !c.exclusive {
		for k, v := range c.m {
			if now.After(v.expires) {
				delete(c.m, k)
			}
		}
	}
	for k := range c.m {
		if len(c.m) <= c.maxSize/2 {
			return
		}
		delete(c.m, k)
	}
}

// clear drops every cached listing.
func (c *dirCache) clear() {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.m = make(map[string]*dirCacheEntry)
}

func (c *dirCache) invalidate(p string) {
	c.mu.Lock()
	delete(c.m, p)
	c.mu.Unlock()
}

func (c *dirCache) invalidatePrefix(p string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	for k := range c.m {
		if k == p || strings.HasPrefix(k, p+"/") {
			delete(c.m, k)
		}
	}
}
