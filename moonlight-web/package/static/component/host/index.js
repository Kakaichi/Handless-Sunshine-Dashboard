var __awaiter = (this && this.__awaiter) || function (thisArg, _arguments, P, generator) {
    function adopt(value) { return value instanceof P ? value : new P(function (resolve) { resolve(value); }); }
    return new (P || (P = Promise))(function (resolve, reject) {
        function fulfilled(value) { try { step(generator.next(value)); } catch (e) { reject(e); } }
        function rejected(value) { try { step(generator["throw"](value)); } catch (e) { reject(e); } }
        function step(result) { result.done ? resolve(result.value) : adopt(result.value).then(fulfilled, rejected); }
        step((generator = generator.apply(thisArg, _arguments || [])).next());
    });
};
import { apiDeleteHost, apiGetHost, isDetailedHost, apiPostPair, apiWakeUp, apiGetUser, apiPatchHost, apiHostCancel } from "../../api.js";
import { ComponentEvent } from "../index.js";
import { getCurrentLanguage, getTranslations } from "../../i18n.js";
import { setContextMenu } from "../context_menu.js";
import { showNotification } from "../notification.js";
import { showMessage } from "../modal/index.js";
import { HOST_IMAGE, HOST_OVERLAY_LOCK, HOST_OVERLAY_NONE, HOST_OVERLAY_OFFLINE } from "../../resources/index.js";
import { buildUrl } from "../../config_.js";
export class Host {
    constructor(api, hostId, host) {
        this.userCache = null;
        this.cache = null;
        this.divElement = document.createElement("div");
        this.imageElement = document.createElement("img");
        this.imageOverlayElement = document.createElement("img");
        this.nameElement = document.createElement("p");
        this.api = api;
        this.hostId = hostId;
        this.cache = host;
        // Configure image
        this.imageElement.classList.add("host-image");
        this.imageElement.src = HOST_IMAGE;
        // Configure image overlay
        this.imageOverlayElement.classList.add("host-image-overlay");
        // Configure name
        this.nameElement.classList.add("host-name");
        // Append elements
        this.divElement.appendChild(this.imageElement);
        this.divElement.appendChild(this.imageOverlayElement);
        this.divElement.appendChild(this.nameElement);
        this.divElement.addEventListener("click", this.onClick.bind(this));
        this.divElement.addEventListener("contextmenu", this.onContextMenu.bind(this));
        // Update cache
        if (host != null) {
            this.updateCache(host, null);
            apiGetUser(api).then((user) => this.userCache = user);
        }
        else {
            this.forceFetch();
        }
    }
    forceFetch() {
        return __awaiter(this, void 0, void 0, function* () {
            const [newCache, user] = yield Promise.all([
                apiGetHost(this.api, {
                    host_id: this.hostId,
                }),
                apiGetUser(this.api)
            ]);
            this.updateCache(newCache, user);
        });
    }
    getCurrentGame() {
        return __awaiter(this, void 0, void 0, function* () {
            yield this.forceFetch();
            if (this.cache && isDetailedHost(this.cache) && this.cache.current_game != 0) {
                return this.cache.current_game;
            }
            else {
                return null;
            }
        });
    }
    onClick(event) {
        return __awaiter(this, void 0, void 0, function* () {
            var _a, _b;
            if (((_a = this.cache) === null || _a === void 0 ? void 0 : _a.paired) == "Paired" && ((_b = this.cache) === null || _b === void 0 ? void 0 : _b.server_state) != null) {
                yield this.forceFetch();
            }
            if (this.hasActiveSession()) {
                this.onContextMenu(event);
                return;
            }
            if (((_a = this.cache) === null || _a === void 0 ? void 0 : _a.server_state) == null) {
                this.onContextMenu(event);
            }
            else if (((_b = this.cache) === null || _b === void 0 ? void 0 : _b.paired) == "Paired") {
                this.divElement.dispatchEvent(new ComponentEvent("ml-hostopen", this));
            }
            else {
                yield this.pair();
            }
        });
    }
    hasActiveSession() {
        return this.cache != null && isDetailedHost(this.cache) && this.cache.current_game != 0;
    }
    startStreamForApp(appId) {
        const query = new URLSearchParams({
            hostId: this.getHostId(),
            appId: appId,
        });
        if (window.matchMedia('(display-mode: standalone)').matches) {
            window.location.href = buildUrl(`/stream.html?${query}`);
        }
        else {
            window.open(buildUrl(`/stream.html?${query}`), "_blank");
        }
    }
    resumeSession() {
        return __awaiter(this, void 0, void 0, function* () {
            yield this.forceFetch();
            if (!this.hasActiveSession()) {
                return;
            }
            this.startStreamForApp(this.cache.current_game);
        });
    }
    stopSession() {
        return __awaiter(this, void 0, void 0, function* () {
            const gameI = getTranslations(getCurrentLanguage()).game;
            yield this.forceFetch();
            const response = yield apiHostCancel(this.api, { host_id: this.hostId });
            if (!response.success) {
                yield showMessage(gameI.failedToCloseApp);
            }
            yield this.forceFetch();
        });
    }
    addSessionMenuElements(elements) {
        if (!this.hasActiveSession()) {
            return;
        }
        const gameI = getTranslations(getCurrentLanguage()).game;
        elements.unshift({
            name: gameI.stopCurrentSession,
            callback: this.stopSession.bind(this),
            classes: ["context-menu-element-red"]
        });
        elements.unshift({
            name: gameI.resumeSession,
            callback: this.resumeSession.bind(this)
        });
    }
    onContextMenu(event) {
            return __awaiter(this, void 0, void 0, function* () {
            var _a, _b, _c, _d, _e, _f, _g, _h, _j, _k, _l;
            if (((_a = this.cache) === null || _a === void 0 ? void 0 : _a.paired) == "Paired" && ((_b = this.cache) === null || _b === void 0 ? void 0 : _b.server_state) != null) {
                yield this.forceFetch();
            }
            const i = getTranslations(getCurrentLanguage()).host;
            const elements = [];
            this.addSessionMenuElements(elements);
            if (((_c = this.cache) === null || _c === void 0 ? void 0 : _c.server_state) != null) {
                elements.push({
                    name: i.showDetails,
                    callback: this.showDetails.bind(this),
                });
                elements.push({
                    name: i.open,
                    callback: () => {
                        this.divElement.dispatchEvent(new ComponentEvent("ml-hostopen", this));
                    }
                });
            }
            else if (((_d = this.cache) === null || _d === void 0 ? void 0 : _d.paired) == "Paired") {
                elements.push({
                    name: i.sendWakeUpPacket,
                    callback: this.wakeUp.bind(this)
                });
            }
            elements.push({
                name: i.reload,
                callback: () => __awaiter(this, void 0, void 0, function* () { return this.forceFetch(); })
            });
            if (((_e = this.cache) === null || _e === void 0 ? void 0 : _e.server_state) != null && ((_f = this.cache) === null || _f === void 0 ? void 0 : _f.paired) == "NotPaired") {
                elements.push({
                    name: i.pair,
                    callback: this.pair.bind(this)
                });
            }
            // Make private / global
            if (((_g = this.userCache) === null || _g === void 0 ? void 0 : _g.role) == "Admin") {
                if (((_h = this.cache) === null || _h === void 0 ? void 0 : _h.owner) == "Global") {
                    elements.push({
                        name: i.makePrivate,
                        callback: this.makePrivate.bind(this),
                        classes: ["context-menu-element-red"]
                    });
                }
                else if (((_j = this.cache) === null || _j === void 0 ? void 0 : _j.owner) == "ThisUser") {
                    elements.push({
                        name: i.makeGlobal,
                        callback: this.makeGlobal.bind(this),
                        classes: ["context-menu-element-red"]
                    });
                }
            }
            if (((_k = this.cache) === null || _k === void 0 ? void 0 : _k.owner) == "ThisUser" || ((_l = this.userCache) === null || _l === void 0 ? void 0 : _l.role) == "Admin") {
                elements.push({
                    name: i.removeHost,
                    callback: this.remove.bind(this)
                });
            }
            setContextMenu(event, {
                elements
            });
        });
    }
    showDetails() {
        return __awaiter(this, void 0, void 0, function* () {
            const i = getTranslations(getCurrentLanguage()).host;
            let host = this.cache;
            if (!host || !isDetailedHost(host)) {
                host = yield apiGetHost(this.api, {
                    host_id: this.hostId,
                });
            }
            if (!host || !isDetailedHost(host)) {
                showNotification(i.failedToGetDetails(this.hostId));
                return;
            }
            this.updateCache(host, this.userCache);
            yield showMessage(i.details(host));
        });
    }
    addHostRemoveListener(listener, options) {
        this.divElement.addEventListener("ml-hostremove", listener, options);
    }
    removeHostRemoveListener(listener, options) {
        this.divElement.removeEventListener("ml-hostremove", listener, options);
    }
    addHostOpenListener(listener, options) {
        this.divElement.addEventListener("ml-hostopen", listener, options);
    }
    removeHostOpenListener(listener, options) {
        this.divElement.removeEventListener("ml-hostopen", listener, options);
    }
    makeGlobal() {
        return __awaiter(this, void 0, void 0, function* () {
            yield apiPatchHost(this.api, {
                host_id: this.hostId,
                change_owner: true,
                owner: null,
            });
            if (this.cache) {
                this.cache.owner = "Global";
            }
        });
    }
    makePrivate() {
        return __awaiter(this, void 0, void 0, function* () {
            var _a;
            const user = (_a = this.userCache) !== null && _a !== void 0 ? _a : yield apiGetUser(this.api);
            yield apiPatchHost(this.api, {
                host_id: this.hostId,
                change_owner: true,
                owner: user.id,
            });
            if (this.cache) {
                this.cache.owner = "ThisUser";
            }
        });
    }
    remove() {
        return __awaiter(this, void 0, void 0, function* () {
            yield apiDeleteHost(this.api, {
                host_id: this.getHostId()
            });
            this.divElement.dispatchEvent(new ComponentEvent("ml-hostremove", this));
        });
    }
    wakeUp() {
        return __awaiter(this, void 0, void 0, function* () {
            const i = getTranslations(getCurrentLanguage()).host;
            yield apiWakeUp(this.api, {
                host_id: this.getHostId()
            });
            yield showMessage(i.wakeUpSent);
        });
    }
    pair() {
        return __awaiter(this, void 0, void 0, function* () {
            var _a, _b, _c, _d;
            const i = getTranslations(getCurrentLanguage()).host;
            if (((_a = this.cache) === null || _a === void 0 ? void 0 : _a.paired) == "Paired") {
                yield this.forceFetch();
                if (((_b = this.cache) === null || _b === void 0 ? void 0 : _b.paired) == "Paired") {
                    showMessage(i.alreadyPaired);
                    return;
                }
            }
            const responseStream = yield apiPostPair(this.api, {
                host_id: this.getHostId()
            });
            if (typeof responseStream.response == "string") {
                throw `failed to pair (stage 1): ${responseStream.response}`;
            }
            const messageAbort = new AbortController();
            showMessage(i.pairPrompt((_d = (_c = this.getCache()) === null || _c === void 0 ? void 0 : _c.name) !== null && _d !== void 0 ? _d : "", responseStream.response.Pin), { signal: messageAbort.signal });
            const resultResponse = yield responseStream.next();
            messageAbort.abort();
            if (!resultResponse) {
                throw "missing stage 2 of pairing";
            }
            else if (typeof resultResponse == "string") {
                throw `failed to pair (stage 2): ${resultResponse}`;
            }
            this.updateCache(resultResponse.Paired, null);
        });
    }
    getHostId() {
        return this.hostId;
    }
    getCache() {
        return this.cache;
    }
    updateCache(host, user) {
        const i = getTranslations(getCurrentLanguage()).host;
        if (this.getHostId() != host.host_id) {
            showNotification(i.overwriteMismatch(this.getHostId(), host.host_id));
            return;
        }
        if (this.cache == null) {
            this.cache = host;
        }
        else {
            // if server_state == null it means this host is offline
            // -> updating cache means setting it to offline
            if (this.cache.server_state != null) {
                Object.assign(this.cache, host);
            }
            else {
                this.cache = host;
            }
        }
        if (user) {
            this.userCache = user;
        }
        // Update Elements
        if (this.hasActiveSession()) {
            this.nameElement.innerText = `${this.cache.name} ${i.sessionActive}`;
        }
        else {
            this.nameElement.innerText = this.cache.name;
        }
        if (this.cache.server_state == null) {
            this.imageOverlayElement.src = HOST_OVERLAY_OFFLINE;
        }
        else if (this.cache.paired != "Paired") {
            this.imageOverlayElement.src = HOST_OVERLAY_LOCK;
        }
        else {
            this.imageOverlayElement.src = HOST_OVERLAY_NONE;
        }
    }
    mount(parent) {
        parent.appendChild(this.divElement);
    }
    unmount(parent) {
        parent.removeChild(this.divElement);
    }
}
