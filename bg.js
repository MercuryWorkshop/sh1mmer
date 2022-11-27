window.dataLayer = window.dataLayer || [];
function gtag() { dataLayer.push(arguments); }
gtag('js', new Date());

gtag('config', 'G-MT82HHR67Y');
window.onload = () => {
    let scrollX = 0;
    let scrollY = 0;
    let hueRot = 0;

    setInterval(() => {
        scrollX += 1;
        scrollY += 1;
        // hueRot += 0.01;
        if (hueRot > 360) hueRot = 0;
        if (scrollX > 4000) scrollX = 0;
        if (scrollY > 2250) scrollY = 0;
        document.getElementById("backgroundimg").style = `transform:translate(-${scrollX}px,-${scrollY}px);filter:hue-rotate(${hueRot}deg)`;
    }, 50);
}