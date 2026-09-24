// SPDX-License-Identifier: Apache-2.0
//! test_runner — 聚合所有带 inline test 的模块
//!
//! `zig build test` 以本文件为根，递归发现所有 `test "..."` 块。
//! 这里不仅再导出顶层模块，还显式 `@import` 每个子文件，确保 0.17-dev 的测试发现机制能看到它们。
//!
//! 编译门（本文件底部的 test）用 `std.testing.refAllDecls` 引用每个文件的**全部顶层声明**：
//! 既阻止 dead-strip 把带 inline test 的文件排除掉（否则会假报「All 1 tests passed」），
//! 也把语义分析的粒度从「文件级可达」提升到「声明级可达」——从未被测试触达的代码同样会被编译。

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
const util_mtls = @import("util/mtls.zig");
const util_rsa_impl = @import("util/rsa_impl.zig");
const util_asn1 = @import("util/asn1.zig");
const util_pkcs12 = @import("util/pkcs12.zig");
const util_template = @import("util/template.zig");
const util_sync = @import("util/sync.zig");
const util_retry = @import("util/retry.zig");
const util_uri = @import("util/uri.zig");
const util_json = @import("util/json.zig");
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
const pay_transfer = @import("pay/transfer/mod.zig");
const pay_redpacket = @import("pay/redpacket/mod.zig");
const pay_v3 = @import("pay/v3/mod.zig");

// —— miniprogram ——
const mp_mod = @import("miniprogram/mod.zig");
const mp_config = @import("miniprogram/config.zig");
const mp_context = @import("miniprogram/context/mod.zig");
const mp_auth = @import("miniprogram/auth/mod.zig");
const mp_qrcode = @import("miniprogram/qrcode/mod.zig");
const mp_urlscheme = @import("miniprogram/urlscheme/mod.zig");
const mp_message = @import("miniprogram/message/mod.zig");
const mp_security = @import("miniprogram/security/mod.zig");
const mp_shortlink = @import("miniprogram/shortlink/mod.zig");
const mp_encryptor = @import("miniprogram/encryptor/mod.zig");
const mp_werun = @import("miniprogram/werun/mod.zig");
const mp_urllink = @import("miniprogram/urllink/mod.zig");
const mp_riskcontrol = @import("miniprogram/riskcontrol/mod.zig");
const mp_redpacketcover = @import("miniprogram/redpacketcover/mod.zig");
const mp_privacy = @import("miniprogram/privacy/mod.zig");
const mp_content = @import("miniprogram/content/mod.zig");
const mp_business = @import("miniprogram/business/mod.zig");
const mp_order = @import("miniprogram/order/mod.zig");
const mp_ocr = @import("miniprogram/ocr/mod.zig");
const mp_subscribe = @import("miniprogram/subscribe/mod.zig");
const mp_analysis = @import("miniprogram/analysis/mod.zig");
const mp_operation = @import("miniprogram/operation/mod.zig");
const mp_tcb = @import("miniprogram/tcb/mod.zig");
const mp_express = @import("miniprogram/express/mod.zig");
const mp_minidrama = @import("miniprogram/minidrama/mod.zig");
const mp_virtualpayment = @import("miniprogram/virtualpayment/mod.zig");

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
const work_server = @import("work/server/mod.zig");
const work_smartbot = @import("work/smartbot/mod.zig");

// —— openplatform ——
const openplatform_mod = @import("openplatform/mod.zig");
const openplatform_config = @import("openplatform/config.zig");
const openplatform_context = @import("openplatform/context/mod.zig");
const openplatform_access_token = @import("openplatform/context/access_token.zig");
const openplatform_account = @import("openplatform/account/mod.zig");
const openplatform_miniprogram = @import("openplatform/miniprogram/mod.zig");
const openplatform_officialaccount = @import("openplatform/officialaccount/mod.zig");

// —— minigame ——
const minigame_mod = @import("minigame/mod.zig");
const minigame_config = @import("minigame/config.zig");
const minigame_context = @import("minigame/context/mod.zig");

// —— aispeech ——
const aispeech_mod = @import("aispeech/mod.zig");

// —— middleware ——
const middleware_mod = @import("middleware/mod.zig");
const middleware_handler = @import("middleware/wechat_handler.zig");

test "test_runner 编译门 — 强制所有模块被解析 (v2)" {
    // 引用每个模块的**全部声明**（含私有项）：既阻止文件被 dead-strip，
    // 也把编译门从「文件级可达」提升到「声明级语义分析」（历史多次被懒分析咬）。
    std.testing.refAllDecls(root_mod);
    std.testing.refAllDecls(wechat);
    std.testing.refAllDecls(cache_mod);
    std.testing.refAllDecls(cache_memory);
    std.testing.refAllDecls(cache_redis);
    std.testing.refAllDecls(cache_memcache);
    std.testing.refAllDecls(credential_mod);
    std.testing.refAllDecls(default_access_token);
    std.testing.refAllDecls(js_ticket);
    std.testing.refAllDecls(work_js_ticket);
    std.testing.refAllDecls(work_access_token);
    std.testing.refAllDecls(util_mod);
    std.testing.refAllDecls(util_http);
    std.testing.refAllDecls(util_crypto);
    std.testing.refAllDecls(util_signature);
    std.testing.refAllDecls(util_time);
    std.testing.refAllDecls(util_param);
    std.testing.refAllDecls(util_util);
    std.testing.refAllDecls(util_error);
    std.testing.refAllDecls(util_rsa);
    std.testing.refAllDecls(util_mtls);
    std.testing.refAllDecls(util_rsa_impl);
    std.testing.refAllDecls(util_asn1);
    std.testing.refAllDecls(util_pkcs12);
    std.testing.refAllDecls(util_template);
    std.testing.refAllDecls(util_sync);
    std.testing.refAllDecls(util_retry);
    std.testing.refAllDecls(util_uri);
    std.testing.refAllDecls(util_json);
    std.testing.refAllDecls(_integration);
    std.testing.refAllDecls(oa_mod);
    std.testing.refAllDecls(oa_config);
    std.testing.refAllDecls(oa_context);
    std.testing.refAllDecls(oa_officialaccount);
    std.testing.refAllDecls(oa_menu);
    std.testing.refAllDecls(oa_oauth);
    std.testing.refAllDecls(oa_basic);
    std.testing.refAllDecls(oa_server);
    std.testing.refAllDecls(oa_message);
    std.testing.refAllDecls(oa_material);
    std.testing.refAllDecls(oa_js);
    std.testing.refAllDecls(oa_user);
    std.testing.refAllDecls(oa_datacube);
    std.testing.refAllDecls(oa_broadcast);
    std.testing.refAllDecls(oa_device);
    std.testing.refAllDecls(oa_customerservice);
    std.testing.refAllDecls(oa_ocr);
    std.testing.refAllDecls(oa_draft);
    std.testing.refAllDecls(oa_freepublish);
    std.testing.refAllDecls(pay_mod);
    std.testing.refAllDecls(pay_config);
    std.testing.refAllDecls(pay_pay);
    std.testing.refAllDecls(pay_order);
    std.testing.refAllDecls(pay_refund);
    std.testing.refAllDecls(pay_notify);
    std.testing.refAllDecls(pay_transfer);
    std.testing.refAllDecls(pay_redpacket);
    std.testing.refAllDecls(pay_v3);
    std.testing.refAllDecls(mp_mod);
    std.testing.refAllDecls(mp_config);
    std.testing.refAllDecls(mp_context);
    std.testing.refAllDecls(mp_auth);
    std.testing.refAllDecls(mp_qrcode);
    std.testing.refAllDecls(mp_urlscheme);
    std.testing.refAllDecls(mp_message);
    std.testing.refAllDecls(mp_security);
    std.testing.refAllDecls(mp_shortlink);
    std.testing.refAllDecls(mp_encryptor);
    std.testing.refAllDecls(mp_werun);
    std.testing.refAllDecls(mp_urllink);
    std.testing.refAllDecls(mp_riskcontrol);
    std.testing.refAllDecls(mp_redpacketcover);
    std.testing.refAllDecls(mp_privacy);
    std.testing.refAllDecls(mp_content);
    std.testing.refAllDecls(mp_business);
    std.testing.refAllDecls(mp_order);
    std.testing.refAllDecls(mp_ocr);
    std.testing.refAllDecls(mp_subscribe);
    std.testing.refAllDecls(mp_analysis);
    std.testing.refAllDecls(mp_operation);
    std.testing.refAllDecls(mp_tcb);
    std.testing.refAllDecls(mp_express);
    std.testing.refAllDecls(mp_minidrama);
    std.testing.refAllDecls(mp_virtualpayment);
    std.testing.refAllDecls(work_mod);
    std.testing.refAllDecls(work_config);
    std.testing.refAllDecls(work_context);
    std.testing.refAllDecls(work_work);
    std.testing.refAllDecls(work_oauth);
    std.testing.refAllDecls(work_jsapi);
    std.testing.refAllDecls(work_externalcontact);
    std.testing.refAllDecls(work_invoice);
    std.testing.refAllDecls(work_addresslist);
    std.testing.refAllDecls(work_appchat);
    std.testing.refAllDecls(work_robot);
    std.testing.refAllDecls(work_message);
    std.testing.refAllDecls(work_material);
    std.testing.refAllDecls(work_msgaudit);
    std.testing.refAllDecls(work_checkin);
    std.testing.refAllDecls(work_kf);
    std.testing.refAllDecls(work_server);
    std.testing.refAllDecls(work_smartbot);
    std.testing.refAllDecls(openplatform_mod);
    std.testing.refAllDecls(openplatform_config);
    std.testing.refAllDecls(openplatform_context);
    std.testing.refAllDecls(openplatform_access_token);
    std.testing.refAllDecls(openplatform_account);
    std.testing.refAllDecls(openplatform_miniprogram);
    std.testing.refAllDecls(openplatform_officialaccount);
    std.testing.refAllDecls(minigame_mod);
    std.testing.refAllDecls(minigame_config);
    std.testing.refAllDecls(minigame_context);
    std.testing.refAllDecls(aispeech_mod);
    std.testing.refAllDecls(middleware_mod);
    std.testing.refAllDecls(middleware_handler);
    try std.testing.expect(true);
}

test "test_runner 自检" {
    try std.testing.expect(true);
}
