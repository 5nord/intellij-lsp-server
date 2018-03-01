package com.ruin.intel.model

import com.intellij.openapi.application.ApplicationManager
import com.intellij.openapi.components.ServiceManager
import com.intellij.openapi.diagnostic.Logger
import com.intellij.openapi.util.Ref
import com.ruin.intel.Util.resolvePsiFromUri
import com.ruin.intel.commands.completion.CompletionCommand
import com.ruin.intel.commands.find.FindDefinitionCommand
import com.ruin.intel.commands.find.FindImplementationCommand
import com.ruin.intel.commands.hover.HoverCommand
import com.ruin.intel.values.*

fun defaultServerCapabilities() : ServerCapabilities {
    return ServerCapabilities(textDocumentSync = null,
            hoverProvider = null,
            completionProvider = CompletionOptions(false, listOf(".", "@", "#")),
            signatureHelpProvider = null,
            definitionProvider = true,
            referencesProvider = false,
            documentHighlightProvider = false,
            documentSymbolProvider = false,
            workspaceSymbolProvider = false,
            codeActionProvider = false,
            codeLensProvider = null,
            documentFormattingProvider = false,
            documentRangeFormattingProvider = false,
            documentOnTypeFormattingProvider = null,
            renameProvider = false,
            documentLinkProvider = null,
            executeCommandProvider = null,
            experimental = null)
}

fun workspace() = ServiceManager.getService<WorkspaceManager>(WorkspaceManager::class.java)!!

class LanguageServerHandlerImpl(val context: Context) : LanguageServerHandler {
    val LOG = Logger.getInstance(LanguageServerHandlerImpl::class.java)

    override fun onInitialize(processId: Int, rootUri: DocumentUri, capabilities: ClientCapabilities) : InitializeResult {
        context.wasInitialized = true
        LOG.info("INIT LSP")
        return InitializeResult(defaultServerCapabilities())
    }

    override fun onShutdown() {
        checkInitialized()
    }

    override fun onExit() {
        checkInitialized()
    }

    override fun onTextDocumentHover(textDocumentIdentifier: TextDocumentIdentifier, position: Position): Hover? {
        checkInitialized()

        // Result<A, B> doesn't allow a null type, but the command can return null...
        val uri = textDocumentIdentifier.uri

        val ref: Ref<MarkedString> = Ref()
        ApplicationManager.getApplication().invokeAndWait {
            val pair = resolvePsiFromUri(uri)
                ?: throw LanguageServerException("File \"$uri\" not tracked by IntelliJ.")
            val (project, file) = pair

            val command = HoverCommand(textDocumentIdentifier, position)
            val result = command.execute(project, file).fold({ value -> value
            }, { error ->
                throw error
            })
            ref.set(result)
            command.dispose()
        }

        return if(ref.get().isEmpty() ) null else Hover(ref.get(), null)
    }

    override fun onTextDocumentDefinition(textDocumentIdentifier: TextDocumentIdentifier, position: Position): List<Location> {
        checkInitialized()

        return execute(FindDefinitionCommand(textDocumentIdentifier, position),
            textDocumentIdentifier.uri)
    }

    override fun onTextDocumentImplementation(textDocumentIdentifier: TextDocumentIdentifier, position: Position): List<Location> {
        checkInitialized()

        return execute(FindImplementationCommand(textDocumentIdentifier, position),
            textDocumentIdentifier.uri)
    }

    override fun onTextDocumentCompletion(textDocumentIdentifier: TextDocumentIdentifier,
                                          position: Position,
                                          triggerKind: Int,
                                          triggerCharacter: String?): CompletionList {
        checkInitialized()

        return execute(CompletionCommand(textDocumentIdentifier, position, triggerKind, triggerCharacter),
            textDocumentIdentifier.uri)
    }

    override fun onNotifyInitialized() {
        context.wasInitialized = true
    }

    override fun onNotifyCancelRequest(id: String) {
        checkInitialized()
    }

    override fun onNotifyTextDocumentDidOpen(textDocument: TextDocumentItem) {
        checkInitialized()
        workspace().onTextDocumentOpened(textDocument)
    }

    override fun onNotifyTextDocumentDidClose(textDocument: VersionedTextDocumentIdentifier) {
        checkInitialized()
        workspace().onTextDocumentClosed(textDocument)
    }

    override fun onNotifyTextDocumentDidChange(textDocument: VersionedTextDocumentIdentifier, contentChanges: List<TextDocumentContentChangeEvent>) {
        checkInitialized()
        workspace().onTextDocumentChanged(textDocument, contentChanges)
    }

    override fun onNotifyTextDocumentDidSave(textDocument: VersionedTextDocumentIdentifier, text: String?) {
        checkInitialized()
        workspace().onTextDocumentSaved(textDocument, text)
    }

    fun checkInitialized() {
        if (!initialized()) {
            throw LanguageServerException("Server was not initialized.")
        }
    }
    fun initialized() = context.wasInitialized
}

fun <T: Any>execute(command: com.ruin.intel.commands.Command<T>, uri: DocumentUri): T {
    val ref: Ref<T> = Ref()
    ApplicationManager.getApplication().invokeAndWait {
        val pair = resolvePsiFromUri(uri)
            ?: throw LanguageServerException("File \"$uri\" not tracked by IntelliJ.")

        val (project, file) = pair
        val result = command.execute(project, file).fold({ value -> value
        }, { error ->
            throw error
        })
        ref.set(result)
        command.dispose()
    }

    return ref.get()
}
