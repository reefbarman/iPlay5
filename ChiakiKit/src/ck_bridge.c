// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
//
// Implementation of ck_bridge.h on top of chiaki-ng's lib.

#include "ck_bridge.h"

#include <chiaki/common.h>
#include <chiaki/controller.h>
#include <chiaki/discovery.h>
#include <chiaki/discoveryservice.h>
#include <chiaki/log.h>
#include <chiaki/opusdecoder.h>
#include <chiaki/orientation.h>
#include <chiaki/regist.h>
#include <chiaki/session.h>
#include <chiaki/thread.h>

#include <arpa/inet.h>
#include <errno.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <netinet/in.h>
#include <pthread.h>
#include <time.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// ------------------------------------------------------------------ helpers

static void copy_str(char *dst, size_t dst_size, const char *src)
{
	if(!dst_size)
		return;
	if(!src)
	{
		dst[0] = '\0';
		return;
	}
	strncpy(dst, src, dst_size - 1);
	dst[dst_size - 1] = '\0';
}

// ---------------------------------------------------------------- library

static CKLogCallback g_log_cb = NULL;
static void *g_log_user = NULL;
static ChiakiLog g_log;

static void global_log_cb(ChiakiLogLevel level, const char *msg, void *user)
{
	(void)user;
	if(g_log_cb)
		g_log_cb(g_log_user, (int)level, msg);
}

int ck_lib_init(void)
{
	chiaki_log_init(&g_log, CHIAKI_LOG_ALL & ~CHIAKI_LOG_VERBOSE, global_log_cb, NULL);
	return (int)chiaki_lib_init();
}

void ck_set_log_callback(CKLogCallback cb, void *user)
{
	g_log_user = user;
	g_log_cb = cb;
}

// -------------------------------------------------------- host discovery

struct CKHostMonitor
{
	ChiakiDiscoveryService service;
	CKHostStatusCallback cb;
	void *user;
	char *host;
	bool had_host;
};

static void fill_status(CKHostStatus *status, ChiakiDiscoveryHost *h)
{
	switch(h->state)
	{
		case CHIAKI_DISCOVERY_HOST_STATE_READY: status->state = CK_HOST_STATE_READY; break;
		case CHIAKI_DISCOVERY_HOST_STATE_STANDBY: status->state = CK_HOST_STATE_STANDBY; break;
		default: status->state = CK_HOST_STATE_UNKNOWN; break;
	}
	status->ps5 = chiaki_discovery_host_is_ps5(h);
	if(h->host_addr)
		copy_str(status->host_addr, sizeof(status->host_addr), h->host_addr);
	copy_str(status->host_name, sizeof(status->host_name), h->host_name);
	copy_str(status->host_id, sizeof(status->host_id), h->host_id);
	copy_str(status->system_version, sizeof(status->system_version), h->system_version);
	copy_str(status->running_app_name, sizeof(status->running_app_name), h->running_app_name);
	copy_str(status->running_app_titleid, sizeof(status->running_app_titleid), h->running_app_titleid);
}

static void host_monitor_cb(ChiakiDiscoveryHost *hosts, size_t hosts_count, void *user)
{
	CKHostMonitor *m = user;
	CKHostStatus status;
	memset(&status, 0, sizeof(status));
	copy_str(status.host_addr, sizeof(status.host_addr), m->host);
	if(hosts_count == 0)
	{
		if(!m->had_host)
			return;
		m->had_host = false;
		status.state = CK_HOST_STATE_UNKNOWN;
		m->cb(m->user, &status);
		return;
	}
	m->had_host = true;
	fill_status(&status, &hosts[0]);
	m->cb(m->user, &status);
}

CKHostMonitor *ck_host_monitor_start(const char *host, CKHostStatusCallback cb, void *user)
{
	if(!host || !cb)
		return NULL;
	CKHostMonitor *m = calloc(1, sizeof(CKHostMonitor));
	if(!m)
		return NULL;
	m->cb = cb;
	m->user = user;
	m->host = strdup(host);

	ChiakiDiscoveryServiceOptions options;
	memset(&options, 0, sizeof(options));
	options.ping_ms = 500;
	options.ping_initial_ms = 0;
	options.hosts_max = 1;
	options.host_drop_pings = 3;
	options.cb = host_monitor_cb;
	options.cb_user = m;
	options.send_host = m->host;

	struct sockaddr_storage addr;
	memset(&addr, 0, sizeof(addr));
	if(strchr(host, ':'))
	{
		addr.ss_family = AF_INET6;
		options.send_addr_size = sizeof(struct sockaddr_in6);
	}
	else
	{
		addr.ss_family = AF_INET;
		options.send_addr_size = sizeof(struct sockaddr_in);
	}
	options.send_addr = &addr;

	if(chiaki_discovery_service_init(&m->service, &options, &g_log) != CHIAKI_ERR_SUCCESS)
	{
		free(m->host);
		free(m);
		return NULL;
	}
	return m;
}

void ck_host_monitor_stop(CKHostMonitor *monitor)
{
	if(!monitor)
		return;
	chiaki_discovery_service_fini(&monitor->service);
	free(monitor->host);
	free(monitor);
}

int ck_wakeup(const char *host, const uint8_t regist_key[16], bool ps5)
{
	// The regist key is an ASCII hex string padded with zero bytes; the wake
	// credential is that string parsed as a 64-bit hex number.
	char key[17];
	memcpy(key, regist_key, 16);
	key[16] = '\0';
	size_t len = strnlen(key, 16);
	if(len == 0 || len > 8)
		return CHIAKI_ERR_INVALID_DATA;
	char *end = NULL;
	uint64_t credential = strtoull(key, &end, 16);
	if(!end || *end != '\0')
		return CHIAKI_ERR_INVALID_DATA;
	return (int)chiaki_discovery_wakeup(&g_log, NULL, host, credential, ps5);
}

// ------------------------------------------------------------ LAN discovery
//
// iOS drops broadcast/multicast UDP unless the app has Apple's multicast
// entitlement, so instead of one broadcast we send the same search packet to
// every address on the local Wi-Fi subnet. The console answers exactly as it
// would to a broadcast.

struct CKDiscovery
{
	ChiakiDiscovery discovery;
	ChiakiDiscoveryThread thread;
	CKHostStatusCallback cb;
	void *user;
	pthread_t sender;
	pthread_mutex_t mutex;
	pthread_cond_t cond;
	bool stop;
};

static void lan_discovery_cb(ChiakiDiscoveryHost *host, void *user)
{
	CKDiscovery *d = user;
	CKHostStatus status;
	memset(&status, 0, sizeof(status));
	fill_status(&status, host);
	d->cb(d->user, &status);
}

static void lan_send_srch(CKDiscovery *d, const char *packet, size_t len, uint32_t addr)
{
	struct sockaddr_in sin;
	memset(&sin, 0, sizeof(sin));
	sin.sin_len = sizeof(sin);
	sin.sin_family = AF_INET;
	sin.sin_port = htons(CHIAKI_DISCOVERY_PORT_PS5);
	sin.sin_addr.s_addr = htonl(addr);
	// Errors (unreachable hosts, broadcast without entitlement) are expected; ignore them
	sendto(d->discovery.socket, packet, len, 0, (struct sockaddr *)&sin, sizeof(sin));
}

static void lan_sweep(CKDiscovery *d)
{
	char packet[512];
	ChiakiDiscoveryPacket p;
	memset(&p, 0, sizeof(p));
	p.cmd = CHIAKI_DISCOVERY_CMD_SRCH;
	p.protocol_version = (char *)CHIAKI_DISCOVERY_PROTOCOL_VERSION_PS5;
	int len = chiaki_discovery_packet_fmt(packet, sizeof(packet), &p);
	if(len < 0 || (size_t)len >= sizeof(packet))
		return;

	struct ifaddrs *ifs = NULL;
	if(getifaddrs(&ifs) != 0)
		return;
	for(struct ifaddrs *i = ifs; i; i = i->ifa_next)
	{
		if(!i->ifa_addr || !i->ifa_netmask || i->ifa_addr->sa_family != AF_INET)
			continue;
		if(!(i->ifa_flags & IFF_UP) || (i->ifa_flags & IFF_LOOPBACK))
			continue;
		// Wi-Fi / Ethernet / personal hotspot only; skip cellular and VPN tunnels
		if(strncmp(i->ifa_name, "en", 2) != 0 && strncmp(i->ifa_name, "bridge", 6) != 0)
			continue;
		uint32_t ip = ntohl(((struct sockaddr_in *)i->ifa_addr)->sin_addr.s_addr);
		uint32_t mask = ntohl(((struct sockaddr_in *)i->ifa_netmask)->sin_addr.s_addr);
		if(mask < 0xFFFFFC00) // bigger than a /22: only sweep our own /24
			mask = 0xFFFFFF00;
		uint32_t net = ip & mask;
		uint32_t bcast = net | ~mask;
		lan_send_srch(d, packet, (size_t)len + 1, bcast);
		unsigned sent = 0;
		for(uint32_t a = net + 1; a < bcast; a++)
		{
			if(a == ip)
				continue;
			lan_send_srch(d, packet, (size_t)len + 1, a);
			if(++sent % 64 == 0)
				usleep(2000); // don't overrun the socket send buffer
		}
	}
	freeifaddrs(ifs);
}

static void *lan_sender_func(void *user)
{
	CKDiscovery *d = user;
	pthread_mutex_lock(&d->mutex);
	while(!d->stop)
	{
		pthread_mutex_unlock(&d->mutex);
		lan_sweep(d);
		pthread_mutex_lock(&d->mutex);
		struct timespec ts;
		clock_gettime(CLOCK_REALTIME, &ts);
		ts.tv_sec += 3;
		while(!d->stop && pthread_cond_timedwait(&d->cond, &d->mutex, &ts) != ETIMEDOUT) {}
	}
	pthread_mutex_unlock(&d->mutex);
	return NULL;
}

CKDiscovery *ck_discovery_start(CKHostStatusCallback cb, void *user)
{
	if(!cb)
		return NULL;
	CKDiscovery *d = calloc(1, sizeof(CKDiscovery));
	if(!d)
		return NULL;
	d->cb = cb;
	d->user = user;
	if(chiaki_discovery_init(&d->discovery, &g_log, AF_INET) != CHIAKI_ERR_SUCCESS)
	{
		free(d);
		return NULL;
	}
	if(chiaki_discovery_thread_start(&d->thread, &d->discovery, lan_discovery_cb, d) != CHIAKI_ERR_SUCCESS)
	{
		chiaki_discovery_fini(&d->discovery);
		free(d);
		return NULL;
	}
	pthread_mutex_init(&d->mutex, NULL);
	pthread_cond_init(&d->cond, NULL);
	if(pthread_create(&d->sender, NULL, lan_sender_func, d) != 0)
	{
		chiaki_discovery_thread_stop(&d->thread);
		chiaki_discovery_fini(&d->discovery);
		pthread_mutex_destroy(&d->mutex);
		pthread_cond_destroy(&d->cond);
		free(d);
		return NULL;
	}
	return d;
}

void ck_discovery_stop(CKDiscovery *d)
{
	if(!d)
		return;
	pthread_mutex_lock(&d->mutex);
	d->stop = true;
	pthread_cond_signal(&d->cond);
	pthread_mutex_unlock(&d->mutex);
	pthread_join(d->sender, NULL);
	chiaki_discovery_thread_stop(&d->thread);
	chiaki_discovery_fini(&d->discovery);
	pthread_mutex_destroy(&d->mutex);
	pthread_cond_destroy(&d->cond);
	free(d);
}

// ------------------------------------------------------------ registration

struct CKRegist
{
	ChiakiRegist regist;
	CKRegistCallback cb;
	void *user;
	bool started;
};

static void regist_cb(ChiakiRegistEvent *event, void *user)
{
	CKRegist *r = user;
	switch(event->type)
	{
		case CHIAKI_REGIST_EVENT_TYPE_FINISHED_SUCCESS: {
			CKRegisteredHost out;
			memset(&out, 0, sizeof(out));
			ChiakiRegisteredHost *h = event->registered_host;
			out.target = (int)h->target;
			out.ps5 = chiaki_target_is_ps5(h->target);
			copy_str(out.server_nickname, sizeof(out.server_nickname), h->server_nickname);
			memcpy(out.server_mac, h->server_mac, sizeof(out.server_mac));
			memcpy(out.regist_key, h->rp_regist_key, sizeof(out.regist_key));
			memcpy(out.rp_key, h->rp_key, sizeof(out.rp_key));
			out.rp_key_type = h->rp_key_type;
			r->cb(r->user, true, &out, NULL);
			break;
		}
		case CHIAKI_REGIST_EVENT_TYPE_FINISHED_CANCELED:
			r->cb(r->user, false, NULL, "Registration cancelled");
			break;
		case CHIAKI_REGIST_EVENT_TYPE_FINISHED_FAILED:
		default:
			r->cb(r->user, false, NULL, "Registration failed. Check the PIN, PSN account ID and that the console is awake.");
			break;
	}
}

CKRegist *ck_regist_start(const char *host, bool ps5, const uint8_t psn_account_id[8], uint32_t pin,
	CKRegistCallback cb, void *user)
{
	if(!host || !cb)
		return NULL;
	CKRegist *r = calloc(1, sizeof(CKRegist));
	if(!r)
		return NULL;
	r->cb = cb;
	r->user = user;

	ChiakiRegistInfo info;
	memset(&info, 0, sizeof(info));
	info.target = ps5 ? CHIAKI_TARGET_PS5_1 : CHIAKI_TARGET_PS4_10;
	info.host = host;
	info.broadcast = false;
	info.psn_online_id = NULL;
	memcpy(info.psn_account_id, psn_account_id, CHIAKI_PSN_ACCOUNT_ID_SIZE);
	info.pin = pin;
	info.console_pin = 0;
	info.holepunch_info = NULL;
	info.rudp = NULL;

	if(chiaki_regist_start(&r->regist, &g_log, &info, regist_cb, r) != CHIAKI_ERR_SUCCESS)
	{
		free(r);
		return NULL;
	}
	r->started = true;
	return r;
}

void ck_regist_destroy(CKRegist *regist)
{
	if(!regist)
		return;
	if(regist->started)
	{
		chiaki_regist_stop(&regist->regist);
		chiaki_regist_fini(&regist->regist);
	}
	free(regist);
}

// ----------------------------------------------------------------- session

#define AUDIO_RING_FRAMES 16384 // ~340 ms of 48 kHz stereo
#define AUDIO_MAX_LATENCY_FRAMES 4800 // trim back when more than 100 ms is queued

struct CKSession
{
	ChiakiLog log;
	ChiakiSession session;
	ChiakiOpusDecoder opus;
	CKSessionCallbacks cb;
	char *host;
	bool initialized;
	bool started;

	pthread_mutex_t state_mutex;
	ChiakiControllerState state;
	ChiakiOrientationTracker orient;

	pthread_mutex_t audio_mutex;
	int16_t audio_ring[AUDIO_RING_FRAMES * 2];
	size_t audio_read;  // frame index
	size_t audio_count; // frames buffered
	uint32_t audio_channels;
};

static void session_log_cb(ChiakiLogLevel level, const char *msg, void *user)
{
	CKSession *s = user;
	if(s->cb.on_log)
		s->cb.on_log(s->cb.user, (int)level, msg);
}

static bool video_cb(uint8_t *buf, size_t buf_size, int32_t frames_lost, bool frame_recovered, void *user)
{
	CKSession *s = user;
	if(!s->cb.on_video)
		return true;
	return s->cb.on_video(s->cb.user, buf, buf_size, frames_lost, frame_recovered);
}

static void event_cb(ChiakiEvent *event, void *user)
{
	CKSession *s = user;
	switch(event->type)
	{
		case CHIAKI_EVENT_CONNECTED:
			if(s->cb.on_event)
				s->cb.on_event(s->cb.user, CK_EVENT_CONNECTED, 0, NULL);
			break;
		case CHIAKI_EVENT_QUIT: {
			if(!s->cb.on_event)
				break;
			char msg[512];
			snprintf(msg, sizeof(msg), "%s%s%s", chiaki_quit_reason_string(event->quit.reason),
				event->quit.reason_str ? ": " : "", event->quit.reason_str ? event->quit.reason_str : "");
			s->cb.on_event(s->cb.user, CK_EVENT_QUIT, (int)event->quit.reason, msg);
			break;
		}
		case CHIAKI_EVENT_LOGIN_PIN_REQUEST:
			if(s->cb.on_event)
				s->cb.on_event(s->cb.user, CK_EVENT_LOGIN_PIN_REQUEST, event->login_pin_request.pin_incorrect ? 1 : 0, NULL);
			break;
		case CHIAKI_EVENT_NICKNAME_RECEIVED:
			if(s->cb.on_event)
				s->cb.on_event(s->cb.user, CK_EVENT_NICKNAME, 0, event->server_nickname);
			break;
		case CHIAKI_EVENT_KEYBOARD_OPEN:
			if(s->cb.on_event)
				s->cb.on_event(s->cb.user, CK_EVENT_KEYBOARD_OPEN, 0, event->keyboard.text_str);
			break;
		case CHIAKI_EVENT_KEYBOARD_TEXT_CHANGE:
			if(s->cb.on_event)
				s->cb.on_event(s->cb.user, CK_EVENT_KEYBOARD_TEXT, 0, event->keyboard.text_str);
			break;
		case CHIAKI_EVENT_KEYBOARD_REMOTE_CLOSE:
			if(s->cb.on_event)
				s->cb.on_event(s->cb.user, CK_EVENT_KEYBOARD_CLOSE, 0, NULL);
			break;
		case CHIAKI_EVENT_RUMBLE:
			if(s->cb.on_rumble)
				s->cb.on_rumble(s->cb.user, event->rumble.left, event->rumble.right);
			break;
		case CHIAKI_EVENT_TRIGGER_EFFECTS:
			if(s->cb.on_trigger_effects)
				s->cb.on_trigger_effects(s->cb.user,
					event->trigger_effects.type_left, event->trigger_effects.left,
					event->trigger_effects.type_right, event->trigger_effects.right);
			break;
		default:
			break;
	}
}

static void audio_settings_cb(uint32_t channels, uint32_t rate, void *user)
{
	CKSession *s = user;
	CHIAKI_LOGI(&s->log, "Audio: %u channels at %u Hz", channels, rate);
	pthread_mutex_lock(&s->audio_mutex);
	s->audio_channels = channels;
	s->audio_read = 0;
	s->audio_count = 0;
	pthread_mutex_unlock(&s->audio_mutex);
}

static void audio_frame_cb(int16_t *buf, size_t samples_count, void *user)
{
	CKSession *s = user;
	pthread_mutex_lock(&s->audio_mutex);
	uint32_t ch = s->audio_channels ? s->audio_channels : 2;
	for(size_t i = 0; i < samples_count; i++)
	{
		int16_t l = buf[i * ch];
		int16_t r = ch > 1 ? buf[i * ch + 1] : l;
		if(s->audio_count == AUDIO_RING_FRAMES)
		{
			// full: drop the oldest frame
			s->audio_read = (s->audio_read + 1) % AUDIO_RING_FRAMES;
			s->audio_count--;
		}
		size_t w = (s->audio_read + s->audio_count) % AUDIO_RING_FRAMES;
		s->audio_ring[w * 2] = l;
		s->audio_ring[w * 2 + 1] = r;
		s->audio_count++;
	}
	// keep latency bounded if the consumer fell behind (e.g. after a hitch)
	if(s->audio_count > AUDIO_MAX_LATENCY_FRAMES * 2)
	{
		size_t drop = s->audio_count - AUDIO_MAX_LATENCY_FRAMES;
		s->audio_read = (s->audio_read + drop) % AUDIO_RING_FRAMES;
		s->audio_count -= drop;
	}
	pthread_mutex_unlock(&s->audio_mutex);
}

static void haptics_cb(uint8_t *buf, size_t buf_size, void *user)
{
	CKSession *s = user;
	if(!s->cb.on_haptics || buf_size < 4 || buf_size % 4)
		return;
	s->cb.on_haptics(s->cb.user, (const int16_t *)buf, buf_size / 4);
}

CKSession *ck_session_create(const CKSessionConfig *config, const CKSessionCallbacks *callbacks)
{
	if(!config || !config->host || !callbacks)
		return NULL;
	CKSession *s = calloc(1, sizeof(CKSession));
	if(!s)
		return NULL;
	s->cb = *callbacks;
	s->host = strdup(config->host);
	s->audio_channels = 2;
	pthread_mutex_init(&s->state_mutex, NULL);
	pthread_mutex_init(&s->audio_mutex, NULL);
	chiaki_controller_state_set_idle(&s->state);
	chiaki_orientation_tracker_init(&s->orient);

	uint32_t mask = CHIAKI_LOG_ALL;
	if(!config->verbose_log)
		mask &= ~(CHIAKI_LOG_VERBOSE | CHIAKI_LOG_DEBUG);
	chiaki_log_init(&s->log, mask, session_log_cb, s);

	ChiakiConnectInfo info;
	memset(&info, 0, sizeof(info));
	info.ps5 = config->ps5;
	info.host = s->host;
	memcpy(info.regist_key, config->regist_key, sizeof(info.regist_key));
	memcpy(info.morning, config->rp_key, sizeof(info.morning));
	info.video_profile.width = config->width;
	info.video_profile.height = config->height;
	info.video_profile.max_fps = config->max_fps;
	info.video_profile.bitrate = config->bitrate_kbps;
	info.video_profile.codec = config->ps5 ? (ChiakiCodec)config->codec : CHIAKI_CODEC_H264;
	info.video_profile_auto_downgrade = true;
	info.enable_keyboard = config->enable_keyboard;
	info.enable_dualsense = config->enable_dualsense;
	info.audio_video_disabled = 0;
	info.auto_regist = false;
	info.holepunch_session = NULL;
	info.rudp_sock = NULL;
	info.packet_loss_max = config->packet_loss_max > 0 ? config->packet_loss_max : 0.05;
	info.enable_idr_on_fec_failure = true;
	info.enable_takion_v20 = config->enable_takion_v20;

	if(chiaki_session_init(&s->session, &info, &s->log) != CHIAKI_ERR_SUCCESS)
	{
		free(s->host);
		free(s);
		return NULL;
	}
	s->initialized = true;

	chiaki_opus_decoder_init(&s->opus, &s->log);
	chiaki_opus_decoder_set_cb(&s->opus, audio_settings_cb, audio_frame_cb, s);
	ChiakiAudioSink audio_sink;
	chiaki_opus_decoder_get_sink(&s->opus, &audio_sink);
	chiaki_session_set_audio_sink(&s->session, &audio_sink);

	if(config->enable_dualsense)
	{
		ChiakiAudioSink haptics_sink;
		memset(&haptics_sink, 0, sizeof(haptics_sink));
		haptics_sink.user = s;
		haptics_sink.frame_cb = haptics_cb;
		chiaki_session_set_haptics_sink(&s->session, &haptics_sink);
	}

	chiaki_session_set_video_sample_cb(&s->session, video_cb, s);
	chiaki_session_set_event_cb(&s->session, event_cb, s);
	return s;
}

int ck_session_start(CKSession *s)
{
	if(!s || s->started)
		return CHIAKI_ERR_UNKNOWN;
	ChiakiErrorCode err = chiaki_session_start(&s->session);
	if(err == CHIAKI_ERR_SUCCESS)
		s->started = true;
	return (int)err;
}

void ck_session_stop(CKSession *s)
{
	if(s && s->started)
		chiaki_session_stop(&s->session);
}

void ck_session_destroy(CKSession *s)
{
	if(!s)
		return;
	if(s->started)
	{
		chiaki_session_stop(&s->session);
		chiaki_session_join(&s->session);
	}
	if(s->initialized)
	{
		chiaki_session_fini(&s->session);
		chiaki_opus_decoder_fini(&s->opus);
	}
	pthread_mutex_destroy(&s->state_mutex);
	pthread_mutex_destroy(&s->audio_mutex);
	free(s->host);
	free(s);
}

int ck_session_request_idr(CKSession *s)
{
	if(!s || !s->started)
		return CHIAKI_ERR_UNINITIALIZED;
	return (int)chiaki_session_request_idr(&s->session);
}

int ck_session_set_login_pin(CKSession *s, const char *pin)
{
	if(!s || !pin)
		return CHIAKI_ERR_UNKNOWN;
	return (int)chiaki_session_set_login_pin(&s->session, (const uint8_t *)pin, strlen(pin));
}

int ck_session_goto_bed(CKSession *s)
{
	if(!s || !s->started)
		return CHIAKI_ERR_UNINITIALIZED;
	return (int)chiaki_session_goto_bed(&s->session);
}

double ck_session_measured_bitrate_mbps(CKSession *s)
{
	if(!s || !s->started)
		return 0.0;
	return s->session.stream_connection.measured_bitrate;
}

double ck_session_packet_loss(CKSession *s)
{
	if(!s || !s->started)
		return 0.0;
	return s->session.stream_connection.congestion_control.packet_loss;
}

double ck_session_rtt_ms(CKSession *s)
{
	if(!s || !s->started)
		return 0.0;
	return (double)s->session.rtt_us / 1000.0;
}

int ck_session_takion_version(CKSession *s)
{
	if(!s || !s->started)
		return 0;
	uint8_t version = s->session.stream_connection.takion.version;
	return (version >= 7 && version <= 20) ? version : 0;
}

int ck_session_keyboard_set_text(CKSession *s, const char *text)
{
	if(!s || !s->started || !text)
		return CHIAKI_ERR_UNINITIALIZED;
	return (int)chiaki_session_keyboard_set_text(&s->session, text);
}

int ck_session_keyboard_accept(CKSession *s)
{
	if(!s || !s->started)
		return CHIAKI_ERR_UNINITIALIZED;
	return (int)chiaki_session_keyboard_accept(&s->session);
}

int ck_session_keyboard_reject(CKSession *s)
{
	if(!s || !s->started)
		return CHIAKI_ERR_UNINITIALIZED;
	return (int)chiaki_session_keyboard_reject(&s->session);
}

// Controller ---------------------------------------------------------------

static void push_state_locked(CKSession *s)
{
	if(s->started)
		chiaki_session_set_controller_state(&s->session, &s->state);
}

void ck_session_set_pad(CKSession *s, const CKPadState *pad)
{
	if(!s || !pad)
		return;
	pthread_mutex_lock(&s->state_mutex);
	s->state.buttons = pad->buttons;
	s->state.l2_state = pad->l2;
	s->state.r2_state = pad->r2;
	s->state.left_x = pad->left_x;
	s->state.left_y = pad->left_y;
	s->state.right_x = pad->right_x;
	s->state.right_y = pad->right_y;
	push_state_locked(s);
	pthread_mutex_unlock(&s->state_mutex);
}

void ck_session_set_motion(CKSession *s, float gx, float gy, float gz, float ax, float ay, float az, uint32_t timestamp_us)
{
	if(!s)
		return;
	pthread_mutex_lock(&s->state_mutex);
	// accel_zero_applied=true: no recentring, and accel_zero is never dereferenced
	chiaki_orientation_tracker_update(&s->orient, gx, gy, gz, ax, ay, az, NULL, true, timestamp_us);
	chiaki_orientation_tracker_apply_to_controller_state(&s->orient, &s->state);
	push_state_locked(s);
	pthread_mutex_unlock(&s->state_mutex);
}

int ck_session_touch_start(CKSession *s, uint16_t x, uint16_t y)
{
	if(!s)
		return -1;
	pthread_mutex_lock(&s->state_mutex);
	int id = chiaki_controller_state_start_touch(&s->state, x, y);
	push_state_locked(s);
	pthread_mutex_unlock(&s->state_mutex);
	return id;
}

void ck_session_touch_move(CKSession *s, int id, uint16_t x, uint16_t y)
{
	if(!s || id < 0)
		return;
	pthread_mutex_lock(&s->state_mutex);
	chiaki_controller_state_set_touch_pos(&s->state, (uint8_t)id, x, y);
	push_state_locked(s);
	pthread_mutex_unlock(&s->state_mutex);
}

void ck_session_touch_stop(CKSession *s, int id)
{
	if(!s || id < 0)
		return;
	pthread_mutex_lock(&s->state_mutex);
	chiaki_controller_state_stop_touch(&s->state, (uint8_t)id);
	push_state_locked(s);
	pthread_mutex_unlock(&s->state_mutex);
}

// Audio --------------------------------------------------------------------

size_t ck_session_audio_read(CKSession *s, int16_t *out, size_t frames)
{
	if(!s)
	{
		memset(out, 0, frames * 2 * sizeof(int16_t));
		return 0;
	}
	pthread_mutex_lock(&s->audio_mutex);
	size_t n = frames < s->audio_count ? frames : s->audio_count;
	for(size_t i = 0; i < n; i++)
	{
		size_t r = (s->audio_read + i) % AUDIO_RING_FRAMES;
		out[i * 2] = s->audio_ring[r * 2];
		out[i * 2 + 1] = s->audio_ring[r * 2 + 1];
	}
	s->audio_read = (s->audio_read + n) % AUDIO_RING_FRAMES;
	s->audio_count -= n;
	pthread_mutex_unlock(&s->audio_mutex);
	if(n < frames)
		memset(out + n * 2, 0, (frames - n) * 2 * sizeof(int16_t));
	return n;
}

size_t ck_session_audio_buffered(CKSession *s)
{
	if(!s)
		return 0;
	pthread_mutex_lock(&s->audio_mutex);
	size_t n = s->audio_count;
	pthread_mutex_unlock(&s->audio_mutex);
	return n;
}
