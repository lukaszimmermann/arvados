// Copyright (C) The Arvados Authors. All rights reserved.
//
// SPDX-License-Identifier: AGPL-3.0

$(document).on('ready arv:pane:loaded', function() {
    $('[data-mount-mithril]').each(function() {
        m.mount(this, window[$(this).data('mount-mithril')])
    })
})
