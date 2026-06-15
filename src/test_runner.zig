//! test_runner — 聚合所有带 inline test 的模块
//!
//! `zig build test` 以本文件为根，递归发现所有 `test "..."` 块。
//! 这里不仅再导出顶层模块，还显式 `@import` 每个子文件，确保 0.17-dev 的测试发现机制能看到它们。

const std = @import("std");

// —— 顶层 ——
const root_mod = @import("root.zig");
const wechat = @import("wechat.zig");

// —— cache ——
const cache_mod = @import("cache/mod.zig");
const cache_memory = @import("cache/memory.zig");
const cache_redis = @import("cache/redis.zig");
const cache_memcache = @import("cache/memcache.zig");

// —— credential ——
const credential_mod = @import("credential/mod.zig");
const default_access_token = @import("credential/default_access_token.zig");
const js_ticket = @import("credential/js_ticket.zig");
const work_js_ticket = @import("credential/work_js_ticket.zig");
const work_access_token = @import("credential/work_access_token.zig");

// —— util ——
const util_mod = @import("util/mod.zig");
const util_http = @import("util/http.zig");
const util_crypto = @import("util/crypto.zig");
const util_signature = @import("util/signature.zig");
const util_time = @import("util/time.zig");
const util_param = @import("util/param.zig");
const util_util = @import("util/util.zig");
const util_error = @import("util/error.zig");
const util_rsa = @import("util/rsa.zig");
const util_rsa_impl = @import("util/rsa_impl.zig");
const util_asn1 = @import("util/asn1.zig");
const util_pkcs12 = @import("util/pkcs12.zig");
const _integration = @import("integration_test.zig");

// —— officialaccount ——
const oa_mod = @import("officialaccount/mod.zig");
const oa_config = @import("officialaccount/config.zig");
const oa_context = @import("officialaccount/context.zig");
const oa_officialaccount = @import("officialaccount/officialaccount.zig");
const oa_menu = @import("officialaccount/menu/mod.zig");
const oa_oauth = @import("officialaccount/oauth/mod.zig");
const oa_basic = @import("officialaccount/basic/mod.zig");
const oa_server = @import("officialaccount/server/mod.zig");
const oa_message = @import("officialaccount/message/mod.zig");
const oa_material = @import("officialaccount/material/mod.zig");
const oa_js = @import("officialaccount/js/mod.zig");
const oa_user = @import("officialaccount/user/mod.zig");
const oa_datacube = @import("officialaccount/datacube/mod.zig");
const oa_broadcast = @import("officialaccount/broadcast/mod.zig");
const oa_device = @import("officialaccount/device/mod.zig");
const oa_customerservice = @import("officialaccount/customerservice/mod.zig");
const oa_ocr = @import("officialaccount/ocr/mod.zig");
const oa_draft = @import("officialaccount/draft/mod.zig");
const oa_freepublish = @import("officialaccount/freepublish/mod.zig");

// —— pay ——
const pay_mod = @import("pay/mod.zig");
const pay_config = @import("pay/config.zig");
const pay_pay = @import("pay/pay.zig");
const pay_order = @import("pay/order/mod.zig");
const pay_refund = @import("pay/refund/mod.zig");
const pay_notify = @import("pay/notify/mod.zig");

// —— miniprogram ——
const mp_mod = @import("miniprogram/mod.zig");
const mp_config = @import("miniprogram/config.zig");
const mp_context = @import("miniprogram/context/mod.zig");
const mp_auth = @import("miniprogram/auth/mod.zig");
const mp_qrcode = @import("miniprogram/qrcode/mod.zig");
const mp_urlscheme = @import("miniprogram/urlscheme/mod.zig");

// —— work ——
const work_mod = @import("work/mod.zig");
const work_config = @import("work/config.zig");
const work_context = @import("work/context/mod.zig");
const work_work = @import("work/work.zig");
const work_oauth = @import("work/oauth/mod.zig");
const work_jsapi = @import("work/jsapi/mod.zig");
const work_externalcontact = @import("work/externalcontact/mod.zig");
const work_invoice = @import("work/invoice/mod.zig");
const work_addresslist = @import("work/addresslist/mod.zig");
const work_appchat = @import("work/appchat/mod.zig");
const work_robot = @import("work/robot/mod.zig");
const work_message = @import("work/message/mod.zig");
const work_material = @import("work/material/mod.zig");
const work_msgaudit = @import("work/msgaudit/mod.zig");
const work_checkin = @import("work/checkin/mod.zig");
const work_kf = @import("work/kf/mod.zig");

// —— openplatform ——
const openplatform_mod = @import("openplatform/mod.zig");
const openplatform_config = @import("openplatform/config.zig");
const openplatform_context = @import("openplatform/context/mod.zig");
const openplatform_account = @import("openplatform/account/mod.zig");
const openplatform_miniprogram = @import("openplatform/miniprogram/mod.zig");
const openplatform_officialaccount = @import("openplatform/officialaccount/mod.zig");

// —— minigame ——
const minigame_mod = @import("minigame/mod.zig");
const minigame_config = @import("minigame/config.zig");
const minigame_context = @import("minigame/context/mod.zig");

// —— aispeech ——
const aispeech_mod = @import("aispeech/mod.zig");

test "test_runner 编译门 — 强制所有模块被解析 (v2)" {
    // 引用每个模块，阻止任何文件被 dead-strip。
    _ = root_mod;
    _ = wechat;
    _ = cache_mod;
    _ = cache_memory;
    _ = cache_redis;
    _ = cache_memcache;
    _ = credential_mod;
    _ = default_access_token;
    _ = js_ticket;
    _ = work_js_ticket;
    _ = work_access_token;
    _ = util_mod;
    _ = util_http;
    _ = util_crypto;
    _ = util_signature;
    _ = util_time;
    _ = util_param;
    _ = util_util;
    _ = util_error;
    _ = util_rsa;
    _ = util_rsa_impl;
    _ = util_asn1;
    _ = util_pkcs12;
    _ = _integration;
    _ = oa_mod;
    _ = oa_config;
    _ = oa_context;
    _ = oa_officialaccount;
    _ = oa_menu;
    _ = oa_oauth;
    _ = oa_basic;
    _ = oa_server;
    _ = oa_message;
    _ = oa_material;
    _ = oa_js;
    _ = oa_user;
    _ = oa_datacube;
    _ = oa_broadcast;
    _ = oa_device;
    _ = oa_customerservice;
    _ = oa_ocr;
    _ = oa_draft;
    _ = oa_freepublish;
    _ = pay_mod;
    _ = pay_config;
    _ = pay_pay;
    _ = pay_order;
    _ = pay_refund;
    _ = pay_notify;
    _ = mp_mod;
    _ = mp_config;
    _ = mp_context;
    _ = mp_auth;
    _ = mp_qrcode;
    _ = mp_urlscheme;
    _ = work_mod;
    _ = work_config;
    _ = work_context;
    _ = work_work;
    _ = work_oauth;
    _ = work_jsapi;
    _ = work_externalcontact;
    _ = work_invoice;
    _ = work_addresslist;
    _ = work_appchat;
    _ = work_robot;
    _ = work_message;
    _ = work_material;
    _ = work_msgaudit;
    _ = work_checkin;
    _ = work_kf;
    _ = openplatform_mod;
    _ = openplatform_config;
    _ = openplatform_context;
    _ = openplatform_account;
    _ = openplatform_miniprogram;
    _ = openplatform_officialaccount;
    _ = minigame_mod;
    _ = minigame_config;
    _ = minigame_context;
    _ = aispeech_mod;
    try std.testing.expect(true);
}

test "test_runner 自检" {
    try std.testing.expect(true);
}