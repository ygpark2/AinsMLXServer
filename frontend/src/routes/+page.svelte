<script lang="ts">
	import { onMount } from 'svelte';
import {
		Send,
		User,
		Bot,
		Loader2,
		Cpu,
		Plus,
		MessageSquareText,
		Pencil,
		Trash2,
		Check,
		X
	} from 'lucide-svelte';

	interface Message {
		role: 'user' | 'assistant';
		content: string;
	}

	interface Thread {
		id: string;
		title: string;
		preview: string;
		updatedAt: number;
		messages: Message[];
	}

	const shortcuts = ['Write a Go server', 'Explain this code', 'Summarize the architecture'];
	const welcomeMessage: Message = {
		role: 'assistant',
		content: 'Welcome. I am AinsMLXServer. Ask me anything.'
	};

	let nextThreadIndex = 2;
	let threads = $state<Thread[]>([
		{
			id: 'thread-1',
			title: 'General chat',
			preview: 'Welcome to AinsMLXServer.',
			updatedAt: Date.now(),
			messages: [welcomeMessage]
		}
	]);
	let activeThreadId = $state('thread-1');
	let userInput = $state('');
	let isLoading = $state(false);
	let chatContainer = $state<HTMLElement | null>(null);
	let editingThreadId = $state<string | null>(null);
	let editingThreadDraft = $state('');
	let pendingDeleteThreadId = $state<string | null>(null);
	let isHydrated = $state(false);

	const activeThread = $derived(threads.find((thread) => thread.id === activeThreadId) ?? threads[0]);
	const messages = $derived(activeThread?.messages ?? []);

	$effect(() => {
		if (messages.length && chatContainer) {
			chatContainer.scrollTop = chatContainer.scrollHeight;
		}
	});

	$effect(() => {
		if (!isHydrated) return;

		localStorage.setItem(
			'ainsmlxserver-threads',
			JSON.stringify({
				threads,
				activeThreadId,
				nextThreadIndex
			})
		);
	});

	onMount(() => {
		try {
			const raw = localStorage.getItem('ainsmlxserver-threads');
			if (!raw) {
				isHydrated = true;
				return;
			}

			const parsed = JSON.parse(raw) as {
				threads?: Thread[];
				activeThreadId?: string;
				nextThreadIndex?: number;
			};

			if (Array.isArray(parsed.threads) && parsed.threads.length > 0) {
				threads = parsed.threads;
			}

			if (typeof parsed.activeThreadId === 'string') {
				activeThreadId = parsed.activeThreadId;
			}

			if (typeof parsed.nextThreadIndex === 'number' && Number.isFinite(parsed.nextThreadIndex)) {
				nextThreadIndex = parsed.nextThreadIndex;
			}

			if (!threads.some((thread) => thread.id === activeThreadId)) {
				activeThreadId = threads[0]?.id ?? 'thread-1';
			}
		} catch {
			// Ignore malformed persisted state and fall back to defaults.
		} finally {
			isHydrated = true;
		}
	});

	function summarize(text: string, limit = 72) {
		const compact = text.replace(/\s+/g, ' ').trim();
		if (compact.length <= limit) return compact;
		return `${compact.slice(0, limit - 1).trimEnd()}…`;
	}

	function updateThread(threadId: string, updater: (thread: Thread) => Thread) {
		threads = threads.map((thread) => (thread.id === threadId ? updater(thread) : thread));
	}

	function selectThread(threadId: string) {
		if (isLoading) return;
		cancelRename();
		activeThreadId = threadId;
	}

	function createThread() {
		if (isLoading) return;
		cancelRename();

		const id = `thread-${nextThreadIndex++}`;
		const thread: Thread = {
			id,
			title: `Chat ${nextThreadIndex - 1}`,
			preview: 'Start a new conversation.',
			updatedAt: Date.now(),
			messages: [welcomeMessage]
		};

		threads = [thread, ...threads];
		activeThreadId = id;
		userInput = '';
	}

	function startRename(threadId: string) {
		if (isLoading) return;

		const thread = threads.find((item) => item.id === threadId);
		if (!thread) return;

		editingThreadId = threadId;
		editingThreadDraft = thread.title;
	}

	function commitRename(threadId: string) {
		if (isLoading) return;
		const nextTitle = editingThreadDraft.trim();
		if (!nextTitle) {
			cancelRename();
			return;
		}

		updateThread(threadId, (item) => ({
			...item,
			title: nextTitle,
			updatedAt: Date.now()
		}));

		cancelRename();
	}

	function cancelRename() {
		editingThreadId = null;
		editingThreadDraft = '';
	}

	function deleteThread(threadId: string) {
		if (pendingDeleteThreadId === threadId) {
			pendingDeleteThreadId = null;
		}
		if (isLoading) return;
		if (editingThreadId === threadId) {
			cancelRename();
		}
		if (threads.length === 1) {
			threads = [
				{
					id: 'thread-1',
					title: 'General chat',
					preview: 'Welcome to AinsMLXServer.',
					updatedAt: Date.now(),
					messages: [welcomeMessage]
				}
			];
			activeThreadId = 'thread-1';
			return;
		}

		const remaining = threads.filter((thread) => thread.id !== threadId);
		threads = remaining;

		if (activeThreadId === threadId) {
			activeThreadId = remaining[0]?.id ?? 'thread-1';
		}
	}

	function askDeleteThread(threadId: string) {
		if (isLoading) return;
		if (editingThreadId === threadId) {
			cancelRename();
		}
		pendingDeleteThreadId = threadId;
	}

	function closeDeleteModal() {
		pendingDeleteThreadId = null;
	}

	function confirmDeleteThread() {
		if (!pendingDeleteThreadId) return;
		deleteThread(pendingDeleteThreadId);
		pendingDeleteThreadId = null;
	}

	function escapeHtml(input: string) {
		return input
			.replace(/&/g, '&amp;')
			.replace(/</g, '&lt;')
			.replace(/>/g, '&gt;')
			.replace(/"/g, '&quot;')
			.replace(/'/g, '&#39;');
	}

	function formatInline(text: string) {
		let output = escapeHtml(text);
		output = output.replace(/\[([^\]]+)\]\((https?:\/\/[^\s)]+)\)/g, '<a href="$2" target="_blank" rel="noreferrer">$1</a>');
		output = output.replace(/`([^`]+)`/g, '<code>$1</code>');
		output = output.replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>');
		output = output.replace(/\*([^*]+)\*/g, '<em>$1</em>');
		output = output.replace(/~~([^~]+)~~/g, '<s>$1</s>');
		return output;
	}

	function renderMarkdown(source: string) {
		const lines = source.replace(/\r\n/g, '\n').split('\n');
		const blocks: string[] = [];
		let i = 0;

		while (i < lines.length) {
			const line = lines[i];

			if (!line.trim()) {
				i += 1;
				continue;
			}

			if (line.startsWith('```')) {
				const language = line.slice(3).trim();
				i += 1;
				const codeLines: string[] = [];

				while (i < lines.length && !lines[i].startsWith('```')) {
					codeLines.push(lines[i]);
					i += 1;
				}

				if (i < lines.length) i += 1;

				blocks.push(`
					<pre class="code-block">
						${language ? `<div class="code-lang">${escapeHtml(language)}</div>` : ''}
						<code>${escapeHtml(codeLines.join('\n'))}</code>
					</pre>
				`);
				continue;
			}

			if (/^#{1,3}\s+/.test(line)) {
				const level = line.match(/^#{1,3}/)?.[0].length ?? 1;
				const content = line.replace(/^#{1,3}\s+/, '');
				blocks.push(`<h${level}>${formatInline(content)}</h${level}>`);
				i += 1;
				continue;
			}

			if (/^>\s+/.test(line)) {
				const quoteLines: string[] = [];
				while (i < lines.length && /^>\s+/.test(lines[i])) {
					quoteLines.push(lines[i].replace(/^>\s+/, ''));
					i += 1;
				}
				blocks.push(`<blockquote>${quoteLines.map((item) => formatInline(item)).join('<br />')}</blockquote>`);
				continue;
			}

			if (/^[-*]\s+/.test(line)) {
				const items: string[] = [];
				while (i < lines.length && /^[-*]\s+/.test(lines[i])) {
					items.push(lines[i].replace(/^[-*]\s+/, ''));
					i += 1;
				}
				blocks.push(`<ul>${items.map((item) => `<li>${formatInline(item)}</li>`).join('')}</ul>`);
				continue;
			}

			if (/^\d+\.\s+/.test(line)) {
				const items: string[] = [];
				while (i < lines.length && /^\d+\.\s+/.test(lines[i])) {
					items.push(lines[i].replace(/^\d+\.\s+/, ''));
					i += 1;
				}
				blocks.push(`<ol>${items.map((item) => `<li>${formatInline(item)}</li>`).join('')}</ol>`);
				continue;
			}

			if (/^(?:---|\*\*\*|___)\s*$/.test(line.trim())) {
				blocks.push('<hr />');
				i += 1;
				continue;
			}

			const paragraphLines: string[] = [];
			while (
				i < lines.length &&
				lines[i].trim() &&
				!lines[i].startsWith('```') &&
				!/^#{1,3}\s+/.test(lines[i]) &&
				!/^>\s+/.test(lines[i]) &&
				!/^[-*]\s+/.test(lines[i]) &&
				!(/^\d+\.\s+/.test(lines[i])) &&
				!(/^(?:---|\*\*\*|___)\s*$/.test(lines[i].trim()))
			) {
				paragraphLines.push(lines[i]);
				i += 1;
			}

			blocks.push(`<p>${paragraphLines.map((item) => formatInline(item)).join('<br />')}</p>`);
		}

		return blocks.join('');
	}

	async function sendMessage(text = userInput.trim()) {
		if (!text || isLoading) return;

		const threadId = activeThreadId;
		const userMessage: Message = { role: 'user', content: text };

		updateThread(threadId, (thread) => ({
			...thread,
			title: thread.messages.length === 1 ? summarize(text, 42) : thread.title,
			preview: summarize(text),
			updatedAt: Date.now(),
			messages: [...thread.messages, userMessage]
		}));

		userInput = '';
		isLoading = true;

		try {
			const response = await fetch('/v1/chat/completions', {
				method: 'POST',
				headers: { 'Content-Type': 'application/json' },
				body: JSON.stringify({
					messages: [{ role: 'user', content: text }]
				})
			});

			if (!response.ok) throw new Error('Server response error');

			const data = await response.json();
			const assistantMessage: Message = {
				role: 'assistant',
				content: data.choices[0].message.content
			};

			updateThread(threadId, (thread) => ({
				...thread,
				preview: summarize(assistantMessage.content),
				updatedAt: Date.now(),
				messages: [...thread.messages, assistantMessage]
			}));
		} catch (error: any) {
			const errorMessage: Message = {
				role: 'assistant',
				content: `An error occurred: ${error.message}`
			};

			updateThread(threadId, (thread) => ({
				...thread,
				preview: summarize(errorMessage.content),
				updatedAt: Date.now(),
				messages: [...thread.messages, errorMessage]
			}));
		} finally {
			isLoading = false;
		}
	}

	function handleKeydown(e: KeyboardEvent) {
		if (e.key === 'Enter' && !e.shiftKey) {
			e.preventDefault();
			sendMessage();
		}
	}

	$effect(() => {
		if (pendingDeleteThreadId) {
			const onKeydown = (event: KeyboardEvent) => {
				if (event.key === 'Escape') {
					closeDeleteModal();
				}
			};

			window.addEventListener('keydown', onKeydown);
			return () => window.removeEventListener('keydown', onKeydown);
		}
	});
</script>

<div class="page-shell">
	<div class="chat-shell">
		<aside class="sidebar">
			<div class="sidebar-head">
				<div>
					<div class="sidebar-kicker">
						<MessageSquareText size={14} />
						<span>Chats</span>
					</div>
					<h2>Conversations</h2>
					<p>Keep recent prompts grouped by thread.</p>
				</div>

				<button class="new-thread" onclick={createThread} disabled={isLoading} aria-label="Start new chat">
					<Plus size={16} />
					<span>New</span>
				</button>
			</div>

			<div class="thread-list">
				{#each threads as thread}
					<div class={`thread-item ${thread.id === activeThreadId ? 'active' : ''}`}>
						<button class="thread-main" onclick={() => selectThread(thread.id)} disabled={isLoading}>
							<div class="thread-icon">
								<Bot size={14} />
							</div>
							<div class="thread-meta">
								{#if editingThreadId === thread.id}
									<input
										class="thread-rename"
										bind:value={editingThreadDraft}
										disabled={isLoading}
										onkeydown={(e) => {
											if (e.key === 'Enter') {
												e.preventDefault();
												commitRename(thread.id);
											}
											if (e.key === 'Escape') {
												e.preventDefault();
												cancelRename();
											}
										}}
										onblur={() => commitRename(thread.id)}
										autocomplete="off"
									/>
								{:else}
									<strong>{thread.title}</strong>
									<span>{thread.preview}</span>
								{/if}
							</div>
						</button>
						<div class="thread-actions">
							{#if editingThreadId === thread.id}
								<button
									class="icon-button"
									onclick={() => commitRename(thread.id)}
									disabled={isLoading}
									aria-label="Save thread name"
								>
									<Check size={14} />
								</button>
								<button
									class="icon-button"
									onclick={cancelRename}
									disabled={isLoading}
									aria-label="Cancel rename"
								>
									<X size={14} />
								</button>
							{:else}
								<button
									class="icon-button"
									onclick={() => startRename(thread.id)}
									disabled={isLoading}
									aria-label="Rename thread"
								>
									<Pencil size={14} />
								</button>
								<button
									class="icon-button danger"
									onclick={() => askDeleteThread(thread.id)}
									disabled={isLoading}
									aria-label="Delete thread"
								>
									<Trash2 size={14} />
								</button>
							{/if}
						</div>
					</div>
				{/each}
			</div>

			<div class="sidebar-footer">
				<div class="status-pill">
					<span class="status-dot"></span>
					<span>Connected</span>
				</div>
				<p>Active model: MLX-backed local runtime</p>
			</div>
		</aside>

		<section class="workspace">
			<header class="topbar">
				<div class="brand">
					<div class="brand-mark">
						<Bot size={20} />
					</div>
					<div>
						<h1>AinsMLXServer</h1>
						<p>MLX-powered chat runtime</p>
					</div>
				</div>

				<div class="topbar-chip">
					<Cpu size={16} />
					<span>OpenAI-compatible</span>
					<span class="topbar-chip-separator">·</span>
					<span>MLX optimized</span>
				</div>
			</header>

			<main bind:this={chatContainer} class="chat-log">
				{#each messages as msg}
					<div class={`message-row ${msg.role === 'user' ? 'is-user' : 'is-assistant'}`}>
						<div class="message-avatar">
							{#if msg.role === 'user'}
								<User size={16} />
							{:else}
								<Bot size={16} />
							{/if}
						</div>

						<div class={`message-bubble ${msg.role === 'user' ? 'user' : 'assistant'}`}>
							{@html renderMarkdown(msg.content)}
						</div>
					</div>
				{/each}

				{#if isLoading}
					<div class="message-row is-assistant">
						<div class="message-avatar">
							<Bot size={16} />
						</div>
						<div class="message-bubble assistant loading">
							<Loader2 size={16} class="spin" />
							<span>Thinking...</span>
						</div>
					</div>
				{/if}
			</main>

			<footer class="composer">
				<div class="shortcut-row">
					{#each shortcuts as shortcut}
						<button class="shortcut" onclick={() => sendMessage(shortcut)} disabled={isLoading}>
							{shortcut}
						</button>
					{/each}
				</div>

				<div class="composer-row">
					<textarea
						bind:value={userInput}
						onkeydown={handleKeydown}
						placeholder="Type your message here..."
						rows="1"
					></textarea>

					<button
						class="send-button"
						onclick={() => sendMessage()}
						disabled={!userInput.trim() || isLoading}
						aria-label="Send message"
					>
						{#if isLoading}
							<Loader2 size={18} class="spin" />
						{:else}
							<Send size={18} />
						{/if}
					</button>
				</div>

				<p class="composer-note">Enter to send, Shift+Enter for a new line.</p>
			</footer>
		</section>
	</div>

	{#if pendingDeleteThreadId}
		<div class="modal-backdrop">
			<div class="modal-card">
				<div class="modal-topline">
					<div class="modal-icon">
						<Trash2 size={18} />
					</div>
					<button type="button" class="modal-close" onclick={closeDeleteModal} aria-label="Close dialog">
						<X size={16} />
					</button>
				</div>
				<div class="modal-copy">
					<h3>Delete this conversation?</h3>
					<p>
						This will remove
						<strong>{threads.find((thread) => thread.id === pendingDeleteThreadId)?.title ?? 'this thread'}</strong>
						from the sidebar. The messages will be removed from local storage too.
					</p>
				</div>
				<div class="modal-actions">
					<button type="button" class="modal-button secondary" onclick={closeDeleteModal}>Cancel</button>
					<button type="button" class="modal-button danger" onclick={confirmDeleteThread}>Delete</button>
				</div>
			</div>
		</div>
	{/if}
</div>
