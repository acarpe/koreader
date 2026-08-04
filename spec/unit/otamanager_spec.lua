describe("OTAManager module", function()
    local OTAManager

    setup(function()
        require("commonrequire")
        OTAManager = require("ui/otamanager")
    end)

    teardown(function()
        G_reader_settings:delSetting("ota_server")
        G_reader_settings:delSetting("ota_channel")
        G_defaults:delSetting("OTA_SERVER")
    end)

    describe("normalizeServerUrl", function()
        it("should add a missing scheme", function()
            assert.is_equal("http://192.168.1.10:8080/koreader/",
                OTAManager:normalizeServerUrl("192.168.1.10:8080/koreader"))
        end)

        it("should keep an explicit scheme", function()
            assert.is_equal("https://ota.example.org/",
                OTAManager:normalizeServerUrl("https://ota.example.org"))
        end)

        it("should always end with a single slash", function()
            assert.is_equal("http://example.org/ko/",
                OTAManager:normalizeServerUrl("http://example.org/ko"))
            assert.is_equal("http://example.org/ko/",
                OTAManager:normalizeServerUrl("http://example.org/ko/"))
            assert.is_equal("http://example.org/ko/",
                OTAManager:normalizeServerUrl("http://example.org/ko///"))
        end)

        it("should trim surrounding whitespace", function()
            assert.is_equal("http://example.org/",
                OTAManager:normalizeServerUrl("  http://example.org  "))
        end)

        it("should return nil without an error for a blank address", function()
            local server, err = OTAManager:normalizeServerUrl("   ")
            assert.is_nil(server)
            assert.is_nil(err)
        end)

        it("should reject an address without a host", function()
            local server, err = OTAManager:normalizeServerUrl("http://")
            assert.is_nil(server)
            assert.is_truthy(err)
        end)

        it("should reject a non-HTTP scheme", function()
            local server, err = OTAManager:normalizeServerUrl("ftp://example.org/ko")
            assert.is_nil(server)
            assert.is_truthy(err)
        end)
    end)

    describe("getOTAServer", function()
        it("should default to the first mirror", function()
            G_reader_settings:delSetting("ota_server")
            G_defaults:delSetting("OTA_SERVER")
            assert.is_equal(OTAManager.ota_servers[1], OTAManager:getOTAServer())
            assert.is_false(OTAManager:isCustomServer())
        end)

        it("should prefer OTA_SERVER over the mirror list", function()
            G_reader_settings:delSetting("ota_server")
            G_defaults:saveSetting("OTA_SERVER", "http://baked-in.example.org/")
            assert.is_equal("http://baked-in.example.org/", OTAManager:getOTAServer())
            assert.is_true(OTAManager:isCustomServer())
        end)

        it("should prefer the user setting over everything else", function()
            G_defaults:saveSetting("OTA_SERVER", "http://baked-in.example.org/")
            OTAManager:setOTAServer("http://home.example.org/")
            assert.is_equal("http://home.example.org/", OTAManager:getOTAServer())
            assert.is_true(OTAManager:isCustomServer())
        end)

        it("should fall back once the user setting is cleared", function()
            OTAManager:setOTAServer("http://home.example.org/")
            OTAManager:setOTAServer(nil)
            assert.is_nil(G_reader_settings:readSetting("ota_server"))
            assert.is_equal("http://baked-in.example.org/", OTAManager:getOTAServer())
        end)

        it("should not consider a shipped mirror a custom server", function()
            G_defaults:delSetting("OTA_SERVER")
            OTAManager:setOTAServer(OTAManager.ota_servers[2])
            assert.is_false(OTAManager:isCustomServer())
        end)
    end)

    describe("genServerList", function()
        it("should list every mirror plus a custom entry", function()
            local servers = OTAManager:genServerList()
            assert.is_equal(#OTAManager.ota_servers + 1, #servers)
        end)

        it("should check the mirror that is in use, and not the custom entry", function()
            G_defaults:delSetting("OTA_SERVER")
            OTAManager:setOTAServer(OTAManager.ota_servers[2])
            local servers = OTAManager:genServerList()
            assert.is_true(servers[2].checked_func())
            assert.is_false(servers[1].checked_func())
            local custom = servers[#servers]
            assert.is_false(custom.checked_func())
            assert.is_equal("Custom server", custom.text_func())
        end)

        it("should check the custom entry and show the address once one is set", function()
            OTAManager:setOTAServer("http://192.168.1.10:8080/koreader/")
            local servers = OTAManager:genServerList()
            local custom = servers[#servers]
            assert.is_true(custom.checked_func())
            assert.is_true(custom.text_func():find("192.168.1.10:8080/koreader", 1, true) ~= nil)
            for i = 1, #OTAManager.ota_servers do
                assert.is_false(servers[i].checked_func())
            end
        end)

        it("should go back to a mirror when one is tapped", function()
            OTAManager:setOTAServer("http://192.168.1.10:8080/koreader/")
            local servers = OTAManager:genServerList()
            servers[1].callback()
            assert.is_equal(OTAManager.ota_servers[1], OTAManager:getOTAServer())
            assert.is_false(OTAManager:isCustomServer())
        end)
    end)

    describe("getFilename", function()
        it("should compose the kotasync manifest name from model and channel", function()
            local Device = require("device")
            local orig_ota_model = Device.ota_model
            Device.ota_model = "kindlehf"
            OTAManager:setOTAChannel("nightly")
            assert.is_equal("koreader-kindlehf-latest-nightly.kotasync",
                OTAManager:getFilename("kotasync"))
            assert.is_equal("koreader-kindlehf-latest-nightly",
                OTAManager:getFilename("link"))
            assert.is_nil(OTAManager:getFilename("kotasync_typo"))
            assert.is_nil(OTAManager:getFilename(nil))
            Device.ota_model = orig_ota_model
        end)
    end)
end)
