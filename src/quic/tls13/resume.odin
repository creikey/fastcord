package tls13

import "fc:locks"
import "base:runtime"
import "core:crypto"
import "core:mem"
import "core:strings"
import "core:time"

// Ticket_Cache holds TLS 1.3 session tickets keyed by "<host>|tcp" or
// "<host>|quic". Like Chrome, tickets are single-use: a connection takes the
// newest valid ticket and the server's fresh tickets replace it. Safe for
// concurrent use.
Ticket_Cache :: struct {
	mu:        locks.Mutex,
	entries:   map[string][dynamic]Ticket,
	allocator: mem.Allocator,
}

// Tickets kept per key (Cloudflare sends two per connection).
MAX_TICKETS_PER_HOST :: 4

// default_ticket_cache is used when Config.ticket_cache is nil.
default_ticket_cache: Ticket_Cache

@(private)
cache_key :: proc(host: string, quic: bool, allocator := context.temp_allocator) -> string {
	return strings.concatenate({host, "|quic" if quic else "|tcp"}, allocator)
}

@(private)
ticket_destroy :: proc(t: ^Ticket, allocator: mem.Allocator) {
	delete(t.ticket, allocator)
	delete(t.quic_params, allocator)
	crypto.zero_explicit(&t.psk, size_of(t.psk))
	t^ = {}
}

// ticket_cache_put stores a ticket (taking ownership of its slices, which must
// have been allocated with the cache's allocator), evicting the oldest.
ticket_cache_put :: proc(c: ^Ticket_Cache, host: string, quic: bool, t: Ticket) {
	locks.lock(&c.mu)
	defer locks.unlock(&c.mu)
	context.allocator = cache_allocator_locked(c)
	key := cache_key(host, quic)
	list, found := &c.entries[key]
	if !found {
		if c.entries == nil do c.entries = make(map[string][dynamic]Ticket)
		c.entries[strings.clone(key)] = make([dynamic]Ticket)
		list = &c.entries[key]
	}
	if len(list) >= MAX_TICKETS_PER_HOST {
		ticket_destroy(&list[0], c.allocator)
		ordered_remove(list, 0)
	}
	append(list, t)
}

// ticket_cache_take removes and returns the newest unexpired ticket. The
// caller owns it and frees it with ticket_free.
ticket_cache_take :: proc(c: ^Ticket_Cache, host: string, quic: bool) -> (t: Ticket, ok: bool) {
	locks.lock(&c.mu)
	defer locks.unlock(&c.mu)
	list, found := &c.entries[cache_key(host, quic)]
	if !found do return {}, false
	now := time.now()
	for len(list) > 0 {
		t = pop(list)
		age := time.diff(t.received, now)
		if age >= 0 && age < time.Duration(t.lifetime) * time.Second do return t, true
		ticket_destroy(&t, c.allocator)
	}
	return {}, false
}

// ticket_cache_count reports how many tickets are cached for host.
ticket_cache_count :: proc(c: ^Ticket_Cache, host: string, quic: bool) -> int {
	locks.lock(&c.mu)
	defer locks.unlock(&c.mu)
	list, found := c.entries[cache_key(host, quic)]
	return len(list) if found else 0
}

// ticket_cache_clear drops every ticket.
ticket_cache_clear :: proc(c: ^Ticket_Cache) {
	locks.lock(&c.mu)
	defer locks.unlock(&c.mu)
	for k, &list in c.entries {
		for &t in list do ticket_destroy(&t, c.allocator)
		delete(list)
		delete(k, c.allocator)
	}
	clear(&c.entries)
}

ticket_free :: proc(c: ^Ticket_Cache, t: ^Ticket) {
	ticket_destroy(t, cache_allocator(c))
}

// cache_allocator is what ticket slices must be allocated with. Defaults to
// the heap so the global cache never captures a per-test or arena allocator.
cache_allocator :: proc(c: ^Ticket_Cache) -> mem.Allocator {
	locks.lock(&c.mu)
	defer locks.unlock(&c.mu)
	return cache_allocator_locked(c)
}

@(private)
cache_allocator_locked :: proc(c: ^Ticket_Cache) -> mem.Allocator {
	if c.allocator.procedure == nil do c.allocator = runtime.heap_allocator()
	return c.allocator
}

// obfuscated_age is the ticket age in ms plus age_add (RFC 8446 4.2.11.1).
@(private)
obfuscated_age :: proc(t: ^Ticket) -> u32 {
	ms := time.duration_milliseconds(time.diff(t.received, time.now()))
	return u32(u64(max(ms, 0))) + t.age_add
}

// parse_new_session_ticket decodes a NewSessionTicket body and derives its PSK.
// A zero-lifetime ticket comes back with ok=false (nothing to store).
@(private)
parse_new_session_ticket :: proc(suite: Suite, res_master: []byte, body: []byte, allocator: mem.Allocator) -> (t: Ticket, ok: bool, err: Error) {
	hl := suite.hash_len
	r := reader(body)
	t.lifetime = r_u32(&r)
	t.age_add = r_u32(&r)
	tnonce := r_vec8(&r)
	ticket := r_vec16(&r)
	exts := reader(r_vec16(&r))
	if !r_done(&r) || len(ticket) == 0 do return {}, false, .Decode
	if t.lifetime > 604800 do return {}, false, .Illegal_Parameter
	for len(exts.b) > 0 {
		et := r_u16(&exts)
		ed := reader(r_vec16(&exts))
		if !exts.ok do return {}, false, .Decode
		if et == EXT_EARLY_DATA {
			t.max_early = r_u32(&ed)
			if !r_done(&ed) do return {}, false, .Decode
		}
	}
	if t.lifetime == 0 do return {}, false, .None
	t.suite = suite.id
	t.psk_len = hl
	t.received = time.now()
	expand_label(suite, res_master[:hl], "resumption", tnonce, t.psk[:hl])
	t.ticket = make([]byte, len(ticket), allocator)
	copy(t.ticket, ticket)
	return t, true, .None
}
