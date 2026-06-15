import { getCurrentLanguage, getTranslations } from "../../i18n.js";
import { InputComponent } from "../input.js";
import { FormModal } from "../modal/form.js";

// Sunshine / Moonlight HTTP port (matches server/config.json moonlight.default_http_port).
const DEFAULT_MOONLIGHT_HTTP_PORT = 47989;

export class AddHostModal extends FormModal {
    constructor() {
        super();
        this.header = document.createElement("h2");
        const i = getTranslations(getCurrentLanguage()).addHost;
        this.header.innerText = i.header;
        this.address = new InputComponent("address", "text", i.address, {
            formRequired: true
        });
        this.httpPort = new InputComponent("httpPort", "text", i.port, {
            inputMode: "numeric",
            defaultValue: String(DEFAULT_MOONLIGHT_HTTP_PORT),
            value: String(DEFAULT_MOONLIGHT_HTTP_PORT)
        });
    }
    reset() {
        this.address.reset();
        this.httpPort.setValue(String(DEFAULT_MOONLIGHT_HTTP_PORT));
    }
    submit() {
        const address = this.address.getValue();
        const rawPort = this.httpPort.getValue().trim();
        const parsedPort = parseInt(rawPort, 10);
        const httpPort = Number.isFinite(parsedPort) ? parsedPort : DEFAULT_MOONLIGHT_HTTP_PORT;
        return {
            address,
            http_port: httpPort
        };
    }
    mountForm(form) {
        form.appendChild(this.header);
        this.address.mount(form);
        this.httpPort.mount(form);
    }
}
