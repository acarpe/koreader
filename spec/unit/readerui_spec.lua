describe("Readerui module", function()
    local BookList, DocumentRegistry, ReaderUI, DocSettings, UIManager, Screen, util
    local sample_epub = "spec/front/unit/data/juliet.epub"
    local sample_epub2 = "spec/front/unit/data/leaves.epub"
    local sample_txt = "spec/front/unit/data/sample.txt"
    local readerui
    setup(function()
        require("commonrequire")
        disable_plugins()
        BookList = require("ui/widget/booklist")
        DocumentRegistry = require("document/documentregistry")
        ReaderUI = require("apps/reader/readerui")
        DocSettings = require("docsettings")
        UIManager = require("ui/uimanager")
        Screen = require("device").screen
        util = require("util")

        readerui = ReaderUI:new{
            dimen = Screen:getSize(),
            document = DocumentRegistry:openDocument(sample_epub),
        }
    end)
    it("should save settings", function()
        -- remove history settings and sidecar settings
        DocSettings:open(sample_epub):purge()
        local doc_settings = DocSettings:open(sample_epub)
        assert.are.same(doc_settings.data, {doc_path = sample_epub})
        readerui:saveSettings()
        assert.are_not.same(readerui.doc_settings.data, {doc_path = sample_epub})
        doc_settings = DocSettings:open(sample_epub)
        assert.truthy(doc_settings.data.last_xpointer)
        assert.are.same(doc_settings.data.last_xpointer,
                readerui.doc_settings.data.last_xpointer)
    end)
    it("should show reader", function()
        UIManager:quit()
        UIManager:show(readerui)
        UIManager:scheduleIn(1, function()
            UIManager:close(readerui)
            -- We haven't torn it down yet
            ReaderUI.instance = readerui
        end)
        UIManager:run()
    end)
    it("should close document", function()
        readerui:closeDocument()
        assert(readerui.document == nil)
        readerui:onClose()
    end)
    it("should not reset ReaderUI.instance by mistake", function()
        ReaderUI:doShowReader(sample_epub) -- spins up a new, sane instance
        local new_readerui = ReaderUI.instance
        assert.is.truthy(new_readerui.document)
        -- This *will* trip:
        -- * A pair of ReaderUI instance mimsatch warnings (on open/close) because it bypasses the safety of doShowReader!
        -- * A refcount warning from DocumentRegistry, because bypassinf the safeties means that two different instances opened the same Document.
        ReaderUI:new{
            dimen = Screen:getSize(),
            document = DocumentRegistry:openDocument(sample_epub)
        }:onClose()
        assert.is.truthy(new_readerui.document)
        new_readerui:closeDocument()
        new_readerui:onClose()
    end)
    it("should give each book opened in sequence its own partial_md5_checksum", function()
        local files = { sample_epub, sample_epub2, sample_txt }
        -- Earlier tests here deliberately bypass doShowReader's safeties, and leave a scheduled task
        -- that re-seeds ReaderUI.instance behind. Drain it before we rely on that field ourselves.
        fastforward_ui_events()
        ReaderUI.instance = nil
        for i, file in ipairs(files) do
            DocSettings:open(file):purge()
            BookList.resetBookInfoCache(file)
            if i > 1 then
                -- Warm book_info_cache without creating a sidecar, as a book-info property write
                -- (cover extraction, a status set from the file browser, ...) would.
                BookList.setBookInfoCacheProperty(file, "been_opened", true)
            end
        end
        for _, file in ipairs(files) do
            ReaderUI:showReader(file)
            fastforward_ui_events()
            local reader = ReaderUI.instance
            assert.is.truthy(reader)
            assert.are.same(file, reader.document.file)
            reader:closeDocument()
            reader:onClose()
            -- The checksum is this book's identity: it keys the sidecar archive and the statistics
            -- database, so inheriting a previously opened book's value merges their histories.
            assert.are.same(util.partialMD5(file),
                DocSettings:open(file):readSetting("partial_md5_checksum"))
        end
        for _, file in ipairs(files) do
            DocSettings:open(file):purge()
            BookList.resetBookInfoCache(file)
        end
    end)
end)
